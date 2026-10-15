import Foundation

public enum LoginShell {
    /// Apps started from Finder or at login get `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, without the directories
    /// the user's shell profile adds. A profile's `credential_process`, which the AWS SDK runs, often lives
    /// there, so this takes PATH from the user's login shell. Call it once at launch. If the shell does not
    /// answer within `timeout`, PATH stays as it is.
    public static func adoptPATH(timeout: TimeInterval = 5) {
        guard let loginPath = path(timeout: timeout) else { return }
        var entries = loginPath.split(separator: ":").map(String.init)
        let current = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        entries += current.filter { !entries.contains($0) }
        setenv("PATH", entries.joined(separator: ":"), 1)
    }

    /// The user's login shell from the user database, e.g. `/bin/zsh`; `$SHELL` is not set for apps.
    static var executable: String {
        getpwuid(getuid()).map { String(cString: $0.pointee.pw_shell) } ?? "/bin/sh"
    }

    /// PATH as the user's login shell sets it up, or nil if the shell fails or takes too long.
    static func path(timeout: TimeInterval) -> String? {
        let shell = executable
        // The profile may print text of its own; the marker finds the PATH after it.
        let marker = "DLQ_MONITOR_PATH="
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "printf '%s' \"\(marker)$PATH\""]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let range = output.range(of: marker, options: .backwards) else { return nil }
        let path = String(output[range.upperBound...])
        return path.isEmpty ? nil : path
    }
}
