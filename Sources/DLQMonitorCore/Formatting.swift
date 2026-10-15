import Foundation

public enum Format {
    /// Two most significant units: `4d 19h`, `10h 12m`, `35m`, `45s`.
    public static func age(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total)s"
    }

    public static func count(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }

    /// Compact form for the menu bar: `2,083`, `12.4k`.
    public static func compactCount(_ value: Int) -> String {
        value >= 10_000 ? String(format: "%.1fk", Double(value) / 1000) : count(value)
    }

    public static func delta(_ value: Int) -> String {
        value > 0 ? "▲ \(count(value))" : "▼ \(count(-value))"
    }
}
