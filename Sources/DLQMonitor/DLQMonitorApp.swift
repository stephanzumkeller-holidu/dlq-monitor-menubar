import AppKit
import DLQMonitorCore
import SwiftUI

@main
enum Entry {
    static func main() {
        LoginShell.adoptPATH()
        let arguments = CommandLine.arguments
        if arguments.contains("--once") {
            Task { @MainActor in
                exit(await OnceCommand.run())
            }
            dispatchMain()
        }
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.delegate = appDelegate
            // The bundled app sets LSUIElement; this covers `swift run`, which has no Info.plist.
            app.setActivationPolicy(.accessory)
            app.run()
        }
    }

    // NSApplication holds its delegate weakly.
    @MainActor private static let appDelegate = AppDelegate()
}

/// A plain AppKit app rather than a SwiftUI `MenuBarExtra`: the `MenuBarExtra` window does not track the
/// content's size and shows empty glass around it, whereas an `NSPopover` follows `preferredContentSize`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let monitor = QueueMonitor(settings: MonitorSettings())
        statusItemController = StatusItemController(monitor: monitor, state: PopoverState())
        monitor.restartSchedule()
    }
}

/// `DLQMonitor --once`: one refresh of the DLQs printed to stdout, for scripting and smoke tests.
@MainActor
enum OnceCommand {
    static func run() async -> Int32 {
        let settings = MonitorSettings()
        let naming = settings.naming
        do {
            let service = QueueService(clients: try await AWSClients(profile: settings.profile, region: settings.region))
            let urls = try await service.listQueueURLs()
                .filter { naming.isDLQ(QueueName.name(fromURL: $0)) }
            let queues = try await service.fetchStatuses(queueURLs: urls)
                .sorted { ($0.total, $1.name) > ($1.total, $0.name) }
            for queue in queues {
                let age = queue.total == 0 ? "-" : queue.oldestAge.map(Format.age) ?? "pending"
                let inFlight = queue.inFlight > 0 ? "  (\(queue.inFlight) in flight)" : ""
                print(queue.name.padding(toLength: 56, withPad: " ", startingAt: 0)
                    + Format.count(queue.total).leftPadded(to: 8) + age.leftPadded(to: 10) + inFlight)
            }
            let total = queues.reduce(0) { $0 + $1.total }
            print("\(queues.count) DLQs, \(Format.count(total)) messages")
            return 0
        } catch {
            FileHandle.standardError.write(Data("error: \(AWSErrorMessage.describe(error))\n".utf8))
            return 1
        }
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
