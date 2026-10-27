import Foundation

/// A diagnostic, off by default, that writes a line to `~/Library/Logs/Yardlet/blank-frames.log`
/// whenever a task's conversation shows no turn at all although it has some (a blank viewport), and
/// again when it shows turns again, so cases that remain in real use can be captured:
///
///     defaults write com.zzunkie.yardlet Yardlet.debug.blankViewportLog -bool YES
///
/// then quit and open Yardlet. `defaults delete com.zzunkie.yardlet Yardlet.debug.blankViewportLog`
/// turns it off. The setting is read once per launch; while it is off a conversation keeps no
/// monitor and its scroll callbacks skip the check, so it costs nothing.
///
/// Each line names the task, how many turns the conversation drew, where SwiftUI says the viewport
/// is (offset, viewport height, content height, distance from the end), whether it was following,
/// and the last thing that happened to it (sent, streamed, opened, scrolled…).
@MainActor
enum ConversationBlankViewportLog {
    static let defaultsKey = "Yardlet.debug.blankViewportLog"

    /// Read once, when the first conversation asks.
    static var isEnabled: Bool = UserDefaults.yardlet.bool(forKey: defaultsKey)

    /// Where lines go: the log file, or a test's collector.
    static var write: (String) -> Void = { line in appendToFile(line) }

    /// The log in real use: `~/Library/Logs/Yardlet/blank-frames.log`.
    static var liveFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/Yardlet", directoryHint: .isDirectory)
            .appending(path: "blank-frames.log")
    }

    /// Where the file writer appends: the live log, or in a test process a file of its own in the
    /// temporary folder. A conversation a test left behind can still write after the test put the
    /// file writer back, and that line must not reach the person's log.
    static var fileURL: URL = isTestProcess
        ? FileManager.default.temporaryDirectory
            .appending(path: "yardlet-test-logs-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
            .appending(path: "blank-frames.log")
        : liveFileURL

    /// XCTest is loaded: `swift test` or Xcode is running the test bundle.
    static let isTestProcess = NSClassFromString("XCTestCase") != nil

    private static let queue = DispatchQueue(label: "Yardlet.blankViewportLog", qos: .utility)

    /// Waits for the lines already handed to the file writer.
    static func flush() {
        queue.sync {}
    }

    static func appendToFile(_ line: String) {
        let url = fileURL
        let text = "\(Date().formatted(.iso8601)) \(line)\n"
        queue.async {
            let manager = FileManager.default
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !manager.fileExists(atPath: url.path(percentEncoded: false)) {
                manager.createFile(atPath: url.path(percentEncoded: false), contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        }
    }
}

/// One conversation's watch for a blank viewport (`ConversationBlankViewportLog`). The conversation
/// keeps one only while the log is on.
@MainActor
final class ConversationBlankViewportMonitor {
    /// The task the conversation belongs to, for the log.
    var conversationID = "-"
    private var lastAction = "opened"
    private var metrics: TranscriptScrollMetrics?
    private var isFollowing = true
    private var itemCount = 0
    private var visibleCount: Int?
    private var blankSince: Date?

    /// Something happened to the conversation: what a blank viewport that follows is put down to.
    func note(_ action: String) {
        lastAction = action
    }

    func observe(itemCount: Int) {
        self.itemCount = itemCount
        evaluate()
    }

    func observe(_ metrics: TranscriptScrollMetrics, isFollowing: Bool) {
        self.metrics = metrics
        self.isFollowing = isFollowing
        evaluate()
    }

    func observe(visibleItems: Int) {
        visibleCount = visibleItems
        evaluate()
    }

    /// No turn in view while there are turns, in a viewport large enough to show one.
    private var isBlank: Bool {
        guard itemCount > 0, let metrics, metrics.viewport.width >= 80, metrics.viewport.height >= 60 else {
            return false
        }
        let pastContent = metrics.offset >= metrics.height - 1 || metrics.offset + metrics.viewport.height <= 1
        return pastContent || visibleCount == 0
    }

    /// A blank viewport is written down once it has lasted `threshold`: SwiftUI reports the turns in
    /// view between layout passes, and one pass can report none just before the next lays them out,
    /// in the same frame. Its end is written with how long it lasted.
    static let threshold: Duration = .milliseconds(50)
    private var pending: Task<Void, Never>?
    private var isLogged = false

    private func evaluate() {
        let blank = isBlank
        if blank, blankSince == nil {
            blankSince = Date()
            let began = describe()
            pending = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.threshold)
                guard let self, !Task.isCancelled, self.blankSince != nil else { return }
                self.isLogged = true
                ConversationBlankViewportLog.write("blank viewport began: \(began); still blank: \(self.describe())")
            }
        } else if !blank, let since = blankSince {
            blankSince = nil
            pending?.cancel()
            pending = nil
            guard isLogged else { return }
            isLogged = false
            let elapsed = Int(Date().timeIntervalSince(since) * 1000)
            ConversationBlankViewportLog.write("blank viewport ended after \(elapsed) ms: \(describe())")
        }
    }

    private func describe() -> String {
        let geometry = metrics.map {
            String(format: "offset %.0f, viewport %.0fx%.0f, content %.0f, from end %.0f",
                   $0.offset, $0.viewport.width, $0.viewport.height, $0.height, $0.distance)
        } ?? "no geometry"
        return "task \(conversationID), turns \(itemCount), visible \(visibleCount.map(String.init) ?? "?"), "
            + "\(geometry), following \(isFollowing), last \(lastAction)"
    }
}
