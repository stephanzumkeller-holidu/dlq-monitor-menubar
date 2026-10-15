import AppKit
import DLQMonitorCore
import Observation

/// Owns the refresh schedule and the latest snapshot of queue state.
@MainActor
@Observable
final class QueueMonitor {
    enum Level {
        /// No data yet, or the last refresh failed.
        case unknown
        /// Every DLQ is empty.
        case ok
        /// At least one DLQ holds messages.
        case warning
        /// A DLQ grew since the previous refresh, or its oldest message is older than the warning age.
        case critical
    }

    let settings: MonitorSettings

    private(set) var queues: [QueueStatus] = []
    /// Change in message count per queue since the previous successful refresh; only non-zero entries.
    private(set) var deltas: [String: Int] = [:]
    private(set) var lastUpdated: Date?
    private(set) var isRefreshing = false
    /// Why the last refresh failed.
    private(set) var problem: String?
    /// The region the queues are read from: the setting, or the profile's when that is empty.
    private(set) var region: String?

    @ObservationIgnored private var service: QueueService?
    @ObservationIgnored private var serviceKey = ""
    @ObservationIgnored private var queueURLs: [String] = []
    @ObservationIgnored private var queueURLsFetchedAt: Date?
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var scheduleTask: Task<Void, Never>?

    /// New queues appear rarely; re-list them once an hour instead of on every refresh.
    private static let queueListTTL: TimeInterval = 3600
    private static let maxBackoff: TimeInterval = 1800

    init(settings: MonitorSettings) {
        self.settings = settings
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleTask?.cancel() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // Give Wi-Fi a moment to come back before the first request.
            MainActor.assumeIsolated { self?.restartSchedule(initialDelay: 5) }
        }
    }

    // MARK: Derived state

    var dlqs: [QueueStatus] { queues.filter { settings.naming.isDLQ($0.name) } }
    var totalDLQMessages: Int { dlqs.reduce(0) { $0 + $1.total } }

    func isOld(_ queue: QueueStatus) -> Bool {
        guard let age = queue.oldestAge else { return false }
        return age > TimeInterval(settings.ageWarningHours) * 3600
    }

    var level: Level {
        if problem != nil || lastUpdated == nil { return .unknown }
        let dlqs = dlqs
        if dlqs.contains(where: { (deltas[$0.name] ?? 0) > 0 || isOld($0) }) { return .critical }
        return dlqs.contains { $0.total > 0 } ? .warning : .ok
    }

    // MARK: Scheduling

    /// Refreshes now (after `initialDelay`), then on the configured interval until cancelled.
    func restartSchedule(initialDelay: TimeInterval = 0) {
        scheduleTask?.cancel()
        scheduleTask = Task { [weak self] in
            if initialDelay > 0 { try? await Task.sleep(for: .seconds(initialDelay)) }
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                guard let delay = self.nextDelay() else { return }
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// The configured interval, doubled per consecutive failure up to 30 minutes.
    private func nextDelay() -> TimeInterval? {
        guard let interval = settings.interval.seconds else { return nil }
        guard consecutiveFailures > 0 else { return interval }
        let backoff = interval * pow(2, Double(min(consecutiveFailures - 1, 6)))
        return min(backoff, max(interval, Self.maxBackoff))
    }

    // MARK: Refresh

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let service = try await currentService()
            let statuses: [QueueStatus]
            do {
                statuses = try await load(using: service)
            } catch is QueueService.QueueDeleted {
                // A queue was deleted since the last listing.
                queueURLsFetchedAt = nil
                statuses = try await load(using: service)
            }
            apply(statuses)
            problem = nil
            consecutiveFailures = 0
        } catch {
            problem = AWSErrorMessage.describe(error)
            consecutiveFailures += 1
        }
    }

    private func load(using service: QueueService) async throws -> [QueueStatus] {
        if queueURLsFetchedAt.map({ Date().timeIntervalSince($0) > Self.queueListTTL }) ?? true {
            queueURLs = try await service.listQueueURLs()
            queueURLsFetchedAt = Date()
        }
        let naming = settings.naming
        return try await service.fetchStatuses(queueURLs: queueURLs.filter { naming.isDLQ(QueueName.name(fromURL: $0)) })
    }

    private func apply(_ statuses: [QueueStatus]) {
        let previous = Dictionary(queues.map { ($0.name, $0.total) }, uniquingKeysWith: { first, _ in first })
        var newDeltas: [String: Int] = [:]
        for status in statuses {
            if let before = previous[status.name], before != status.total {
                newDeltas[status.name] = status.total - before
            }
        }
        deltas = newDeltas
        queues = statuses
        lastUpdated = Date()
    }

    /// Rebuilds the AWS clients, and with them the credential cache, whenever the profile or region changed.
    private func currentService() async throws -> QueueService {
        if let service, serviceKey == settings.connectionKey { return service }
        region = nil
        let service = QueueService(clients: try await AWSClients(profile: settings.profile, region: settings.region))
        self.service = service
        region = service.clients.region
        serviceKey = settings.connectionKey
        queueURLs = []
        queueURLsFetchedAt = nil
        queues = []
        deltas = [:]
        return service
    }

    func settingsChanged() {
        settings.applyPatternDrafts()
        restartSchedule()
    }
}
