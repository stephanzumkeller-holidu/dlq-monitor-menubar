import AppKit
import DLQMonitorCore
import Observation
import SwiftUI

/// The menu bar item and the popover it opens.
@MainActor
final class StatusItemController: NSObject {
    private let monitor: QueueMonitor
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()

    init(monitor: QueueMonitor, state: PopoverState) {
        self.monitor = monitor
        super.init()

        let hostingController = NSHostingController(rootView: PopoverView(monitor: monitor, state: state))
        // Resize the popover whenever the SwiftUI content's ideal size changes (expanding a section, settings).
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController
        popover.behavior = .transient

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageLeading
        }
        updateButton()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // An accessory app is not active by default; without this, text fields get no focus and the
            // transient popover does not close on outside clicks.
            NSApp.activate()
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Re-renders the menu bar item whenever the monitor's level or DLQ total changes.
    private func updateButton() {
        withObservationTracking {
            guard let button = statusItem.button else { return }
            let total = monitor.totalDLQMessages
            button.image = Self.icon(for: monitor.level)
            button.title = total > 0 ? " \(Format.compactCount(total))" : ""
            button.setAccessibilityLabel(total > 0 ? "\(total) messages in dead-letter queues" : "Dead-letter queues")
            button.toolTip = toolTip()
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateButton() }
        }
    }

    private func toolTip() -> String {
        let status: String
        let dlqs = monitor.dlqs
        let nonEmpty = dlqs.filter { $0.total > 0 }.count
        if monitor.problem != nil {
            status = "Last refresh failed"
        } else if monitor.lastUpdated == nil {
            status = "Loading…"
        } else if nonEmpty == 0 {
            status = "All \(dlqs.count) DLQs are empty"
        } else {
            status = "\(Format.count(monitor.totalDLQMessages)) messages in \(nonEmpty) of \(dlqs.count) DLQs"
        }
        return "DLQ Monitor: \(status)\nClick to show the queues"
    }

    /// Status items render images as templates; a colored state needs a non-template image.
    static func icon(for level: QueueMonitor.Level) -> NSImage {
        let (symbol, color): (String, NSColor?) = switch level {
        case .unknown: ("tray.and.arrow.down", .systemGray)
        case .ok: ("tray", nil)
        case .warning: ("tray.full.fill", .systemOrange)
        case .critical: ("tray.full.fill", .systemRed)
        }
        var configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        if let color {
            configuration = configuration.applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = color == nil
        return image
    }
}
