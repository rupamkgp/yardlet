import AppKit
import Observation
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Sending a message while reading earlier turns takes the conversation to its end without a blank
/// frame. The conversation's turns are a lazy stack: far from its end it has only estimated the rows
/// in between, and scrolling to its edge went to that estimate. The view landed past the last row and
/// drew nothing (the window's white canvas), and in most runs stayed blank until the next update.
///
/// Every frame Core Animation commits after the send is read from the scroll view's layers, in a
/// test window that is never shown; a frame lays out first, as a shown window's display cycle does.
@MainActor
final class ConversationSendJumpTests: XCTestCase {
    @Observable
    final class Feed {
        var entries: [TranscriptEntry]
        var status: SessionStatus = .ready
        init(_ entries: [TranscriptEntry]) { self.entries = entries }
    }

    private struct Host: View {
        let feed: Feed
        let reading: TranscriptReadingPosition
        var body: some View {
            TaskConversationView(
                harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/qa"), entries: feed.entries,
                sessionStatus: feed.status, latestTurnIsComplete: feed.status == .ready,
                transcriptReading: reading
            )
            .frame(width: ConversationSendJumpTests.size.width, height: ConversationSendJumpTests.size.height)
            .background(ParityTheme.canvas)
        }
    }

    private static let size = NSSize(width: 1000, height: 650)
    private static let turnCount = 60

    /// The reader went back to the first turns the window draws, then sends.
    func testSendingFromEarlierTurnsNeverDrawsABlankConversation() throws {
        try checkSend(readingTurn: Self.turnCount - ConversationTurnWindow.initialTurnCount + 1)
    }

    /// The reader paused following just above the end, then sends.
    func testSendingAfterPausingNearTheEndNeverDrawsABlankConversation() throws {
        try checkSend(readingTurn: Self.turnCount - 3)
    }

    /// The reader follows at the end, then sends.
    func testSendingWhileFollowingNeverDrawsABlankConversation() throws {
        try checkSend(readingTurn: nil)
    }

    private func checkSend(readingTurn: Int?, file: StaticString = #filePath, line: UInt = #line) throws {
        let (entries, turnIDs) = Self.conversation()
        let feed = Feed(entries)
        let reading = TranscriptReadingPosition()
        if let readingTurn {
            reading.bookmark = .init(anchorID: turnIDs[readingTurn], fraction: 0, followsLatest: false)
        }
        let host = WindowlessRender.Host(Host(feed: feed, reading: reading), size: Self.size, appearance: .light)
        defer { host.close() }
        let hosting = host.hosting
        let display = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 1_900_000) { _, _ in
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), display, .commonModes)
        defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), display, .commonModes) }
        host.settle(passes: 30)
        let scroll = try XCTUnwrap(Self.conversationScrollView(in: hosting), file: file, line: line)
        if readingTurn != nil {
            XCTAssertGreaterThan(Self.distance(scroll), 48, "the reader is away from the end", file: file, line: line)
        }
        XCTAssertGreaterThan(Self.ink(scroll), 0.02, "the conversation draws before the send", file: file, line: line)

        // Each frame Core Animation commits (its observer runs at 2,000,000).
        var frames: [Double] = []
        let probe = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_100_000) { _, _ in
            if frames.count < 200 { frames.append(Self.ink(scroll)) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), probe, .commonModes)
        // As the app sends: the message is published at once, the task's status a moment later.
        feed.entries.append(TranscriptEntry(content: .user(text: "Next request")))
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        feed.status = .running
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), probe, .commonModes)

        XCTAssertGreaterThan(frames.count, 3, file: file, line: line)
        let blank = frames.indices.filter { frames[$0] < 0.01 }
        XCTAssertEqual(blank, [], "frames drawn blank after the send (of \(frames.count)): \(blank)", file: file, line: line)
        XCTAssertLessThanOrEqual(Self.distance(scroll), 48, "the send went to the end", file: file, line: line)
        let shown = host.accessibilityElements(visibleOnly: true).map(\.description)
        XCTAssertTrue(shown.contains { $0.contains("Next request") }, shown.joined(separator: "\n"), file: file, line: line)
    }

    // MARK: - Fixture

    /// Turns of very different heights, as a working conversation has, so the stack's estimates of
    /// the rows it has not laid out are off.
    private static func conversation() -> ([TranscriptEntry], [String]) {
        var entries: [TranscriptEntry] = []
        var turnIDs: [String] = []
        for turn in 0..<turnCount {
            let request = TranscriptEntry(content: .user(text: "Request \(turn): please look at the module and fix it."))
            turnIDs.append(request.id.uuidString)
            entries.append(request)
            for tool in 0..<(turn % 5 == 0 ? 12 : 2) {
                entries.append(TranscriptEntry(content: .activity(HarnessActivity(
                    id: "bash-\(turn)-\(tool)", kind: "Bash", title: "Bash",
                    input: "swift test --filter Thing\(turn)", output: "ok"), state: .completed)))
            }
            let paragraphs = turn % 7 == 0 ? 40 : (turn % 3 == 0 ? 1 : 6)
            entries.append(TranscriptEntry(content: .assistant(text: (0..<paragraphs).map {
                "Paragraph \($0) of answer \(turn). " + String(repeating: "Some words that wrap across the line. ", count: 8)
            }.joined(separator: "\n\n"), isStreaming: false)))
        }
        return (entries, turnIDs)
    }

    /// The conversation's scroll view: the largest one, as the composer has small ones of its own.
    private static func conversationScrollView(in view: NSView) -> NSScrollView? {
        func all(_ view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(all)
        }
        return all(view).max { $0.frame.height * $0.frame.width < $1.frame.height * $1.frame.width }
    }

    private static func distance(_ scroll: NSScrollView) -> CGFloat {
        (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.maxY
    }

    /// The share of the scroll view's area its committed layers draw on: 0 when they draw nothing.
    private static func ink(_ scroll: NSScrollView) -> Double {
        guard let layer = scroll.layer else { return -1 }
        let width = Int(scroll.bounds.width), height = Int(scroll.bounds.height)
        guard width > 80, height > 8,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = { () -> UnsafeMutablePointer<UInt8>? in
                  // Nothing drawn reads as fully transparent.
                  context.clear(CGRect(x: 0, y: 0, width: width, height: height))
                  layer.render(in: context)
                  return context.data?.assumingMemoryBound(to: UInt8.self)
              }() else { return -1 }
        let bytesPerRow = context.bytesPerRow
        var drawn = 0, total = 0
        for y in stride(from: 4, to: height - 4, by: 3) {
            for x in stride(from: 40, to: width - 40, by: 3) {
                total += 1
                let red = data[y * bytesPerRow + x * 4], alpha = data[y * bytesPerRow + x * 4 + 3]
                // Drawn and not the canvas: text, bubbles and rows are darker than the light canvas.
                if alpha > 0, red < 235 { drawn += 1 }
            }
        }
        return Double(drawn) / Double(max(total, 1))
    }
}
