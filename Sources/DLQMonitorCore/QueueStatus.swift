import Foundation

public struct QueueStatus: Sendable, Equatable, Identifiable {
    public var id: String { name }

    public let name: String
    public let url: String
    /// Messages available for receive.
    public let visible: Int
    /// Messages received by a consumer and not yet deleted or returned (someone may be inspecting the DLQ).
    public let inFlight: Int
    /// CloudWatch `ApproximateAgeOfOldestMessage` in seconds; nil while the queue is empty or no datapoint exists.
    public let oldestAge: TimeInterval?
    /// When CloudWatch recorded `oldestAge`.
    public let oldestAgeTimestamp: Date?

    public init(name: String, url: String, visible: Int, inFlight: Int, oldestAge: TimeInterval? = nil, oldestAgeTimestamp: Date? = nil) {
        self.name = name
        self.url = url
        self.visible = visible
        self.inFlight = inFlight
        self.oldestAge = oldestAge
        self.oldestAgeTimestamp = oldestAgeTimestamp
    }

    public var total: Int { visible + inFlight }
}

public enum QueueName {
    public static func name(fromURL url: String) -> String {
        String(url.split(separator: "/").last ?? Substring(url))
    }

    /// The SQS page of the AWS console for one queue.
    ///
    /// The queue URL goes into the fragment encoded like JavaScript's `encodeURIComponent`, which is what the
    /// console's own links use: `.`, `-`, `_` and `~` stay literal. The console does not resolve `%2E`/`%2D`/`%5F`.
    public static func consoleURL(queueURL: String, region: String) -> URL? {
        let encoded = queueURL.addingPercentEncoding(withAllowedCharacters: uriComponentAllowed) ?? queueURL
        return URL(string: "https://\(region).console.aws.amazon.com/sqs/v3/home?region=\(region)#/queues/\(encoded)")
    }

    /// RFC 3986 unreserved characters.
    private static let uriComponentAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}
