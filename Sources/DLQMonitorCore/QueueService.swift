import AWSCloudWatch
import AWSSQS
import Foundation

/// Reads queue depth from SQS and the age of the oldest message from CloudWatch.
///
/// Counts come from `GetQueueAttributes`: real time and practically free. SQS has no attribute for message
/// age, so that comes from CloudWatch, which is billed per metric requested — hence only for queues that
/// currently hold messages.
public struct QueueService: Sendable {
    public let clients: AWSClients

    /// At most this many `GetQueueAttributes` calls run at once.
    static let maxConcurrentCalls = 10

    public init(clients: AWSClients) {
        self.clients = clients
    }

    /// A queue in the list no longer exists; list the queues again.
    public struct QueueDeleted: Error {
        public let url: String
    }

    /// Every queue URL in the account and region; the caller picks the DLQs by name.
    public func listQueueURLs() async throws -> [String] {
        var urls: [String] = []
        var token: String?
        repeat {
            let output = try await clients.sqs.listQueues(input: ListQueuesInput(maxResults: 1000, nextToken: token))
            urls += output.queueUrls ?? []
            token = output.nextToken
        } while token != nil
        return urls.sorted()
    }

    /// Fetches counts for all given queues in parallel, then ages for the non-empty ones.
    public func fetchStatuses(queueURLs: [String], now: Date = Date()) async throws -> [QueueStatus] {
        let fetched = try await Self.concurrentMap(queueURLs, limit: Self.maxConcurrentCalls) { url in
            try await fetchCounts(queueURL: url)
        }
        var counts: [String: (visible: Int, inFlight: Int)] = [:]
        for (url, visible, inFlight) in fetched {
            counts[url] = (visible, inFlight)
        }

        let nonEmpty = queueURLs.filter { (counts[$0]?.visible ?? 0) + (counts[$0]?.inFlight ?? 0) > 0 }
        let ages = try await fetchOldestAges(queueNames: nonEmpty.map(QueueName.name(fromURL:)), now: now)

        return queueURLs.map { url in
            let name = QueueName.name(fromURL: url)
            let count = counts[url] ?? (0, 0)
            return QueueStatus(
                name: name, url: url, visible: count.visible, inFlight: count.inFlight,
                oldestAge: ages[name]?.value, oldestAgeTimestamp: ages[name]?.timestamp
            )
        }
    }

    private func fetchCounts(queueURL: String) async throws -> (String, Int, Int) {
        let output: GetQueueAttributesOutput
        do {
            output = try await clients.sqs.getQueueAttributes(input: GetQueueAttributesInput(
                attributeNames: [.approximatenumberofmessages, .approximatenumberofmessagesnotvisible],
                queueUrl: queueURL
            ))
        } catch is QueueDoesNotExist {
            throw QueueDeleted(url: queueURL)
        }
        let attributes = output.attributes ?? [:]
        return (
            queueURL,
            Int(attributes["ApproximateNumberOfMessages"] ?? "") ?? 0,
            Int(attributes["ApproximateNumberOfMessagesNotVisible"] ?? "") ?? 0
        )
    }

    /// Latest `ApproximateAgeOfOldestMessage` per queue from the last 20 minutes.
    /// CloudWatch lags a few minutes, and an SQS queue idle for six hours stops publishing for a while,
    /// so a queue may legitimately have no datapoint.
    public func fetchOldestAges(queueNames: [String], now: Date = Date()) async throws -> [String: (value: Double, timestamp: Date)] {
        guard !queueNames.isEmpty else { return [:] }
        var ages: [String: (value: Double, timestamp: Date)] = [:]
        // GetMetricData accepts at most 500 queries per request.
        for chunkStart in stride(from: 0, to: queueNames.count, by: 500) {
            let chunk = Array(queueNames[chunkStart..<min(chunkStart + 500, queueNames.count)])
            var nextToken: String?
            repeat {
                let input = GetMetricDataInput(
                    endTime: now,
                    metricDataQueries: chunk.enumerated().map { index, name in
                        CloudWatchClientTypes.MetricDataQuery(
                            id: "q\(index)",
                            label: name,
                            metricStat: .init(
                                metric: .init(
                                    dimensions: [.init(name: "QueueName", value: name)],
                                    metricName: "ApproximateAgeOfOldestMessage",
                                    namespace: "AWS/SQS"
                                ),
                                period: 60,
                                stat: "Maximum"
                            )
                        )
                    },
                    nextToken: nextToken,
                    scanBy: .timestampDescending,
                    startTime: now.addingTimeInterval(-20 * 60)
                )
                let output = try await clients.cloudWatch.getMetricData(input: input)
                for result in output.metricDataResults ?? [] {
                    guard let label = result.label, let value = result.values?.first,
                          let timestamp = result.timestamps?.first else { continue }
                    if let existing = ages[label], existing.timestamp >= timestamp { continue }
                    ages[label] = (value, timestamp)
                }
                nextToken = output.nextToken
            } while nextToken != nil
        }
        return ages
    }

    /// `transform` over `items`, in order, with at most `limit` calls at a time. The first call runs alone: until
    /// it has filled the credential cache, parallel calls would each run the profile's credential source, and an
    /// interactive one (an MFA prompt, say) would ask once per call.
    static func concurrentMap<Item: Sendable, Result: Sendable>(
        _ items: [Item], limit: Int, _ transform: @escaping @Sendable (Item) async throws -> Result
    ) async throws -> [Result] {
        guard let first = items.first else { return [] }
        var results = [Result?](repeating: nil, count: items.count)
        results[0] = try await transform(first)
        try await withThrowingTaskGroup(of: (Int, Result).self) { group in
            var next = 1
            while next < items.count, next <= limit {
                let index = next
                group.addTask { (index, try await transform(items[index])) }
                next += 1
            }
            while let (index, result) = try await group.next() {
                results[index] = result
                if next < items.count {
                    let index = next
                    group.addTask { (index, try await transform(items[index])) }
                    next += 1
                }
            }
        }
        return results.map { $0! }
    }
}
