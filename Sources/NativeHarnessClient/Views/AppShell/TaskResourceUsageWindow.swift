import AppKit
import SwiftUI

/// Task Resource Usage: each task's processes with their CPU, memory and process count, the
/// busiest first, in the native table Activity Monitor uses. A shared Codex App Server is its own
/// row. It updates as the sampler publishes; clicking a task's row opens the task in the main
/// window. It only shows; nothing here stops a process.
struct TaskResourceUsageWindow: View {
    static let sceneID = "task-resource-usage"

    let monitor: TaskResourceMonitor
    var onOpenTask: (UUID) -> Void = { _ in }
    @State private var selection: TaskResourceOwner?
    @State private var sortOrder = [KeyPathComparator(\TaskResourceMonitor.Row.cpuSortValue, order: .reverse)]

    private var rows: [TaskResourceMonitor.Row] {
        monitor.rows.sorted(using: sortOrder)
    }

    var body: some View {
        Group {
            if monitor.rows.isEmpty {
                ContentUnavailableView(L10n.string("No running task processes"), systemImage: "cpu")
            } else {
                table
            }
        }
        .frame(minWidth: 560, minHeight: 220)
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(L10n.string("Task"), value: \.title) { row in
                HStack(spacing: 6) {
                    HarnessIdentityIcon(harness: row.harness, size: 16)
                    Text(row.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .help(row.title)
            }
            .width(min: 160, ideal: 300)
            TableColumn(L10n.string("Runs in"), value: \.location) { row in
                Text(row.location)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 110)
            TableColumn(L10n.string("CPU %"), value: \.cpuSortValue) { row in
                Text(verbatim: row.cpuPercent.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "–")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 56, ideal: 64, max: 96)
            TableColumn(L10n.string("Memory"), value: \.memoryBytes) { row in
                Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(clamping: row.memoryBytes),
                                                         countStyle: .memory))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 64, ideal: 80, max: 110)
            TableColumn(L10n.string("Processes"), value: \.processCount) { row in
                Text(verbatim: "\(row.processCount)")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 56, ideal: 72, max: 96)
        }
        // A click opens the task; the selection is let go, so the next click on it opens it again.
        .onChange(of: selection) { _, owner in
            guard let owner else { return }
            selection = nil
            if let task = owner.taskID { onOpenTask(task) }
        }
    }

    /// Brings the main window forward, out of the Dock if it was minimized. Returns false when
    /// there is no main window, closed with Yardlet still running.
    @MainActor
    @discardableResult
    static func bringMainWindowForward() -> Bool {
        guard let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeMain
        }) else { return false }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    /// Opens a main window again once it was closed: the main window's `openWindow` action, kept
    /// by the window each time it appears (`MainWindow`). A Dock click does the same through SwiftUI.
    @MainActor static var reopenMainWindow: (() -> Void)?
}

/// Window > Task Resource Usage. The window's scene leaves out SwiftUI's own Window menu item, so
/// this is the one entry there.
struct TaskResourceUsageCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button(L10n.string("Task Resource Usage")) {
                openWindow(id: TaskResourceUsageWindow.sceneID)
            }
        }
    }
}
