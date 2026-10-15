import Foundation

/// Reads a profile's settings from the AWS config file the way the AWS CLI does.
public enum AWSConfigFile {
    /// The `region` of `profile` in `$AWS_CONFIG_FILE` or `~/.aws/config`, if it sets one.
    public static func region(profile: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let path = environment["AWS_CONFIG_FILE"].map { ($0 as NSString).expandingTildeInPath }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".aws/config")
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return region(profile: profile, config: text)
    }

    /// The default profile's section is `[default]` (or `[profile default]`); any other is `[profile <name>]`.
    static func region(profile: String, config: String) -> String? {
        let headers: Set<String> = profile == "default" ? ["default", "profile default"] : ["profile \(profile)"]
        var inProfile = false
        for rawLine in config.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let name = line.dropFirst().prefix { $0 != "]" }.split(separator: " ").joined(separator: " ")
                inProfile = headers.contains(name)
            } else if inProfile, let equals = line.firstIndex(of: "="),
                      line[..<equals].trimmingCharacters(in: .whitespaces) == "region" {
                let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}
