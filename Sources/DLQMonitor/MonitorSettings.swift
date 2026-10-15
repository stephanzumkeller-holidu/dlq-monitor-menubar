import DLQMonitorCore
import Foundation
import Observation

enum RefreshInterval: Int, CaseIterable, Identifiable {
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case thirtyMinutes = 1800
    case manual = 0

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .oneMinute: "1m"
        case .fiveMinutes: "5m"
        case .fifteenMinutes: "15m"
        case .thirtyMinutes: "30m"
        case .manual: "Manual"
        }
    }

    var seconds: TimeInterval? { self == .manual ? nil : TimeInterval(rawValue) }
}

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class MonitorSettings {
    private enum Key {
        static let interval = "refreshInterval"
        static let profile = "awsProfile"
        static let region = "awsRegion"
        static let ageWarningHours = "ageWarningHours"
        static let dlqPattern = "dlqPattern"
        static let tagPattern = "tagPattern"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var interval: RefreshInterval { didSet { defaults.set(interval.rawValue, forKey: Key.interval) } }
    /// Profile in `~/.aws/config` that reads the queues; it must land in the AWS account that owns them.
    var profile: String { didSet { defaults.set(profile, forKey: Key.profile) } }
    /// Empty: the profile's `region` from `~/.aws/config`.
    var region: String { didSet { defaults.set(region, forKey: Key.region) } }
    /// A DLQ whose oldest message is older than this turns the status red.
    var ageWarningHours: Int { didSet { defaults.set(ageWarningHours, forKey: Key.ageWarningHours) } }

    static let defaultDLQPattern = QueueNaming.defaultDLQPattern
    /// No tags: every queue shows its full name.
    static let defaultTagPattern = ""

    /// Regex that selects the dead-letter queues to monitor. Only patterns that compile get here.
    private(set) var dlqPattern: String
    /// Regex with named groups for the service tag; empty for no tags. Only valid patterns get here.
    private(set) var tagPattern: String
    /// What the Settings fields hold. They replace `dlqPattern` / `tagPattern` on Apply, and only if valid,
    /// so a half-typed pattern never reclassifies the queues.
    var dlqPatternDraft: String
    var tagPatternDraft: String
    var dlqPatternError: String? { QueueNaming.dlqPatternError(dlqPatternDraft) }
    var tagPatternError: String? { QueueNaming.tagPatternError(tagPatternDraft) }

    /// The patterns, compiled.
    private(set) var naming: QueueNaming

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        interval = RefreshInterval(rawValue: defaults.object(forKey: Key.interval) as? Int ?? -1) ?? .fiveMinutes
        profile = defaults.string(forKey: Key.profile) ?? "default"
        region = defaults.string(forKey: Key.region) ?? ""
        ageWarningHours = defaults.object(forKey: Key.ageWarningHours) as? Int ?? 72
        // Fall back to the defaults if a stored pattern does not compile (e.g. one set with `defaults write`).
        let storedDLQPattern = defaults.string(forKey: Key.dlqPattern) ?? Self.defaultDLQPattern
        let dlqPattern = QueueNaming.dlqPatternError(storedDLQPattern) == nil ? storedDLQPattern : Self.defaultDLQPattern
        let storedTagPattern = defaults.string(forKey: Key.tagPattern) ?? Self.defaultTagPattern
        let tagPattern = QueueNaming.tagPatternError(storedTagPattern) == nil ? storedTagPattern : Self.defaultTagPattern
        self.dlqPattern = dlqPattern
        self.tagPattern = tagPattern
        dlqPatternDraft = dlqPattern
        tagPatternDraft = tagPattern
        naming = Self.makeNaming(dlqPattern: dlqPattern, tagPattern: tagPattern)
    }

    /// Adopts the pattern drafts that are valid; an invalid one keeps the last valid pattern.
    func applyPatternDrafts() {
        if dlqPatternError == nil, dlqPatternDraft != dlqPattern {
            dlqPattern = dlqPatternDraft
            defaults.set(dlqPattern, forKey: Key.dlqPattern)
        }
        if tagPatternError == nil, tagPatternDraft != tagPattern {
            tagPattern = tagPatternDraft
            defaults.set(tagPattern, forKey: Key.tagPattern)
        }
        naming = Self.makeNaming(dlqPattern: dlqPattern, tagPattern: tagPattern)
    }

    /// Both patterns were validated before they were stored, and the defaults are valid.
    private static func makeNaming(dlqPattern: String, tagPattern: String) -> QueueNaming {
        (try? QueueNaming(dlqPattern: dlqPattern, tagPattern: tagPattern))
            ?? (try! QueueNaming(dlqPattern: defaultDLQPattern, tagPattern: defaultTagPattern))
    }

    /// Identifies everything that changes which AWS account and queues are read.
    var connectionKey: String { [profile, region].joined(separator: "|") }
}
