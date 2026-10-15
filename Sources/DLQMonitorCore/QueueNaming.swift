import Foundation

/// How queue names are read: which queues are dead-letter queues to monitor, and which part of a name is the
/// service tag. Both are regular expressions the user configures.
public struct QueueNaming: Sendable {
    /// A queue whose name matches is monitored; every other queue is ignored.
    public let dlqPattern: String
    /// Regex with a named group `service` and optionally `purpose`, matched against the full queue name.
    /// Empty, or no match, shows the full name without a tag.
    public let tagPattern: String

    /// Names ending in `dlq` or `dead-letter` / `deadletterqueue` and the like, any case, also FIFO queues.
    public static let defaultDLQPattern = #"(?i)(dlq|dead[-_]?letter([-_]?queue)?)(\.fifo)?$"#

    private let dlqRegex: NSRegularExpression
    private let tagRegex: NSRegularExpression?

    public init(dlqPattern: String, tagPattern: String = "") throws {
        if let error = Self.dlqPatternError(dlqPattern) { throw PatternError(message: error) }
        if let error = Self.tagPatternError(tagPattern) { throw PatternError(message: error) }
        self.dlqPattern = dlqPattern
        self.tagPattern = tagPattern
        dlqRegex = try NSRegularExpression(pattern: dlqPattern)
        tagRegex = tagPattern.isEmpty ? nil : try NSRegularExpression(pattern: tagPattern)
    }

    public func isDLQ(_ name: String) -> Bool {
        dlqRegex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    /// The service tag, if the name has one, and the text shown next to it.
    public func label(for name: String) -> (tag: String?, title: String) {
        let nsName = name as NSString
        guard let tagRegex, let match = tagRegex.firstMatch(in: name, range: NSRange(location: 0, length: nsName.length)) else {
            return (nil, name)
        }
        func group(_ group: String) -> String? {
            // `range(withName:)` raises for a group the pattern does not define.
            guard tagPattern.contains("(?<\(group)>") else { return nil }
            let range = match.range(withName: group)
            return range.location == NSNotFound || range.length == 0 ? nil : nsName.substring(with: range)
        }
        return (group("service"), group("purpose") ?? name)
    }

    // MARK: Validation

    public struct PatternError: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Why `pattern` cannot select the DLQs, or nil if it can.
    public static func dlqPatternError(_ pattern: String) -> String? {
        if pattern.isEmpty { return "Enter a pattern; an empty one would match every queue." }
        return compileError(pattern)
    }

    /// Why `pattern` cannot extract the service tag, or nil if it can. Empty is valid: no tags.
    public static func tagPatternError(_ pattern: String) -> String? {
        if pattern.isEmpty { return nil }
        if let error = compileError(pattern) { return error }
        return pattern.contains("(?<service>") ? nil : "Needs a named group (?<service>…)."
    }

    private static func compileError(_ pattern: String) -> String? {
        do {
            _ = try NSRegularExpression(pattern: pattern)
            return nil
        } catch {
            return "Not a valid regular expression."
        }
    }
}
