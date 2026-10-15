import AppKit
import DLQMonitorCore
import ServiceManagement
import SwiftUI

/// View-local UI state. Kept in an @Observable class because @State needs a macro plugin that only Xcode ships.
@MainActor
@Observable
final class PopoverState {
    var showEmptyDLQs = false
    var showSettings = false
    var hoveredQueue: String?
    var isLaunchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    var launchAtLoginError: String?
}

struct PopoverView: View {
    @Bindable var monitor: QueueMonitor
    @Bindable var state: PopoverState

    private var settings: MonitorSettings { monitor.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let problem = monitor.problem {
                ProblemBanner(message: problem)
            }
            // A ScrollView in a menu bar window does not size to its content, so scroll only when the list
            // would not fit, and then at a fixed height.
            if visibleRowCount > Self.maxRowsWithoutScrolling {
                ScrollView { queueList }.frame(height: 460)
            } else {
                queueList
            }
            Divider()
            controls
            if state.showSettings {
                SettingsForm(settings: settings, apply: monitor.settingsChanged)
            }
        }
        .padding(12)
        .frame(width: 490)
    }

    private static let maxRowsWithoutScrolling = 18

    private var visibleRowCount: Int {
        let dlqs = monitor.dlqs
        let nonEmpty = dlqs.filter { $0.total > 0 }.count
        let expandedEmpty = state.showEmptyDLQs ? dlqs.count - nonEmpty : 0
        return nonEmpty + expandedEmpty
    }

    private var queueList: some View {
        VStack(alignment: .leading, spacing: 2) {
            dlqSection
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text("DLQ Monitor").font(.headline)
                Text("\(settings.profile) · \(monitor.region ?? "no region") · \(settings.dlqPattern)")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("AWS profile \(settings.profile) in \(monitor.region ?? "no region yet"), monitoring the queues whose names match \(settings.dlqPattern)")
            }
            Spacer()
            if monitor.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await monitor.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("r")
                .help("Refresh now (⌘R)")
            }
        }
    }

    // MARK: Queue sections

    @ViewBuilder
    private var dlqSection: some View {
        let dlqs = monitor.dlqs
        let nonEmpty = dlqs.filter { $0.total > 0 }.sorted(by: Self.byCountThenName)
        let empty = dlqs.filter { $0.total == 0 }

        SectionHeader(
            title: "Dead-letter queues",
            detail: monitor.lastUpdated == nil ? nil
                : "\(Format.count(monitor.totalDLQMessages)) messages in \(nonEmpty.count) of \(dlqs.count)"
        )
        if monitor.lastUpdated == nil {
            Text(monitor.problem == nil ? "Loading…" : "No data yet.")
                .foregroundStyle(.secondary).padding(.vertical, 4)
        } else if nonEmpty.isEmpty {
            Label("All \(dlqs.count) DLQs are empty", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).padding(.vertical, 4)
        }
        ForEach(nonEmpty) { row($0) }
        if !empty.isEmpty {
            DisclosureGroup(isExpanded: $state.showEmptyDLQs) {
                ForEach(empty) { row($0) }
            } label: {
                Text("\(empty.count) empty DLQs").foregroundStyle(.secondary)
            }
            .padding(.top, 4)
            .help(state.showEmptyDLQs ? "Hide the empty DLQs" : "Show the empty DLQs")
        }
    }

    private func row(_ queue: QueueStatus) -> some View {
        QueueRow(
            queue: queue,
            delta: monitor.deltas[queue.name],
            isOld: monitor.isOld(queue),
            naming: settings.naming,
            region: monitor.region ?? settings.region,
            state: state
        )
    }

    private static func byCountThenName(_ lhs: QueueStatus, _ rhs: QueueStatus) -> Bool {
        lhs.total != rhs.total ? lhs.total > rhs.total : lhs.name < rhs.name
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Refresh").foregroundStyle(.secondary)
                Picker("Refresh", selection: Bindable(settings).interval) {
                    ForEach(RefreshInterval.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: settings.interval) { monitor.restartSchedule() }
                .help("How often to read the queues. Manual: only with the refresh button or ⌘R.")
            }
            HStack {
                Spacer()
                if let lastUpdated = monitor.lastUpdated {
                    Text("Updated \(lastUpdated.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("Counts are live from SQS. Ages come from CloudWatch and lag a few minutes.")
                }
            }
            HStack {
                LaunchAtLoginToggle(state: state)
                Spacer()
                Button(state.showSettings ? "Hide Settings" : "Settings…") { state.showSettings.toggle() }
                    .help(state.showSettings ? "Hide the settings" : "AWS profile, region, queue patterns and warning age")
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
                    .help("Quit DLQ Monitor (⌘Q)")
            }
        }
    }
}

// MARK: - Rows

private struct SectionHeader: View {
    let title: String
    let detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 2)
    }
}

private struct QueueRow: View {
    let queue: QueueStatus
    let delta: Int?
    let isOld: Bool
    let naming: QueueNaming
    let region: String
    let state: PopoverState

    private var isHovered: Bool { state.hoveredQueue == queue.name }

    var body: some View {
        let label = naming.label(for: queue.name)
        HStack(spacing: 6) {
            Button(action: activate) {
                HStack(spacing: 8) {
                    if let tag = label.tag {
                        Text(tag)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                            .frame(width: 64, alignment: .leading)
                    }
                    Text(label.title)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    if let delta {
                        Text(Format.delta(delta))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(delta > 0 ? .red : .green)
                    }
                    Text(Format.count(queue.total))
                        .monospacedDigit()
                        .fontWeight(queue.total > 0 ? .semibold : .regular)
                        .foregroundStyle(queue.total > 0 ? .primary : .secondary)
                        .frame(minWidth: 48, alignment: .trailing)
                    Text(ageText)
                        .monospacedDigit()
                        .foregroundStyle(isOld ? .red : .secondary)
                        .frame(width: 62, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tooltip)
            actions
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(isHovered ? Color.primary.opacity(0.08) : .clear))
        .onHover { hovering in
            if hovering {
                state.hoveredQueue = queue.name
            } else if isHovered {
                state.hoveredQueue = nil
            }
        }
        .contextMenu {
            Button("Open in AWS Console", action: openConsole)
            Button("Copy Queue Name") { copy(queue.name) }
            Button("Copy Queue URL") { copy(queue.url) }
        }
    }

    /// Shown on hover. They always take their space, so the count and age columns line up across rows.
    private var actions: some View {
        HStack(spacing: 2) {
            ActionIcon(systemImage: "doc.on.doc", help: "Copy the queue name") { copy(queue.name) }
            ActionIcon(systemImage: "arrow.up.forward.square", help: "Open the queue in the AWS console", action: openConsole)
        }
        .opacity(isHovered ? 1 : 0)
        .allowsHitTesting(isHovered)
    }

    private var ageText: String {
        guard queue.total > 0 else { return "—" }
        return queue.oldestAge.map(Format.age) ?? "pending"
    }

    private var tooltip: String {
        var lines = [
            queue.name,
            "",
            "Click: open in the AWS console",
            "⌥-click: copy the queue name",
            "Right-click: more actions",
            "",
            "\(Format.count(queue.visible)) available, \(Format.count(queue.inFlight)) in flight",
        ]
        if let timestamp = queue.oldestAgeTimestamp {
            lines.append("Oldest-message age from CloudWatch at \(timestamp.formatted(date: .omitted, time: .shortened))")
        } else if queue.total > 0 {
            lines.append("CloudWatch has no recent age datapoint yet")
        }
        return lines.joined(separator: "\n")
    }

    private func activate() {
        // Check the click event itself as well as the live keyboard state; either may miss the flag
        // depending on when SwiftUI runs the action.
        let flags = NSEvent.modifierFlags.union(NSApp.currentEvent?.modifierFlags ?? [])
        if flags.contains(.option) {
            copy(queue.name)
        } else {
            openConsole()
        }
    }

    private func openConsole() {
        if let url = QueueName.consoleURL(queueURL: queue.url, region: region) {
            NSWorkspace.shared.open(url)
        }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

private struct ActionIcon: View {
    static let width: CGFloat = 18

    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).frame(width: Self.width)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

// MARK: - Banners, settings, login item

private struct ProblemBanner: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Refresh failed", systemImage: "exclamationmark.triangle").font(.callout.weight(.semibold))
            Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(5).textSelection(.enabled)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.15)))
    }
}

private struct SettingsForm: View {
    @Bindable var settings: MonitorSettings
    let apply: () -> Void

    var body: some View {
        Form {
            TextField("Profile", text: $settings.profile)
                .help("Profile in ~/.aws/config that reads the queues; it must resolve to the AWS account that owns them")
            TextField("Region", text: $settings.region, prompt: Text("from profile"))
                .help("AWS region of the queues, e.g. us-east-1. Empty: the profile's region from ~/.aws/config")
            TextField("DLQ pattern", text: $settings.dlqPatternDraft)
                .help("Regular expression that selects the queues to monitor by name, e.g. ^myapp-.*_dlq$")
            if let error = settings.dlqPatternError {
                PatternErrorText(error: error, current: settings.dlqPattern)
            }
            TextField("Tag pattern", text: $settings.tagPatternDraft, prompt: Text("none"))
                .help("Optional regular expression with the named groups (?<service>…) and (?<purpose>…), matched against the queue name. Empty: no tags.")
            if let error = settings.tagPatternError {
                PatternErrorText(error: error, current: settings.tagPattern.isEmpty ? "no tags" : settings.tagPattern)
            }
            LabeledContent("Warning age") {
                HStack(spacing: 4) {
                    TextField("Warning age", value: warningHours, format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                    Stepper("Warning age", value: warningHours, in: Self.warningHoursRange)
                        .labelsHidden()
                    Text("hours")
                }
            }
            .help("A DLQ whose oldest message is older than this many hours (1–336) shows its age in red and turns the menu bar icon red")
            HStack {
                Spacer()
                Button("Apply", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .help("Use the new settings and refresh now (↩)")
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(.callout)
    }

    private static let warningHoursRange = 1...336

    /// Typed values outside the range are clamped, like the stepper's.
    private var warningHours: Binding<Int> {
        Binding(
            get: { settings.ageWarningHours },
            set: { settings.ageWarningHours = min(max($0, Self.warningHoursRange.lowerBound), Self.warningHoursRange.upperBound) }
        )
    }
}

private struct PatternErrorText: View {
    let error: String
    let current: String

    var body: some View {
        Text("\(error) Still using \(current).")
            .font(.caption).foregroundStyle(.red)
    }
}

private struct LaunchAtLoginToggle: View {
    let state: PopoverState

    /// Login items need an app bundle; `swift run` has none.
    private let isBundled = Bundle.main.bundleIdentifier != nil

    var body: some View {
        Toggle("Launch at login", isOn: Binding(get: { state.isLaunchAtLoginEnabled }, set: update))
            .toggleStyle(.checkbox)
            .disabled(!isBundled)
            .help(state.launchAtLoginError ?? (isBundled ? "Start DLQ Monitor when you log in" : "Only available in the bundled app"))
    }

    private func update(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            state.launchAtLoginError = nil
        } catch {
            state.launchAtLoginError = error.localizedDescription
        }
        state.isLaunchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }
}
