import AppKit
import CoreFoundation
import XCTest

@MainActor
final class BlankFrameProbeTests: XCTestCase {
    func testAnOtherwiseEmptyRunLoopStillRecordsAMissingConversationAsBlank() {
        let hosting = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let mode = CFRunLoopMode(rawValue: "Yardlet.BlankFrameProbe.\(UUID().uuidString)" as CFString)
        let probe = BlankFrameProbe(hosting: hosting, runLoopMode: mode, conversation: { nil })
        defer { probe.close() }
        probe.record("no input is pending")

        // A mode containing only observers has nothing to wait for and exits without drawing.
        // The probe must provide a display cycle without borrowing the app's unrelated sources.
        CFRunLoopRunInMode(mode, 0.01, false)
        probe.stop()

        XCTAssertGreaterThan(probe.result.frames, 0, "A display cycle must not depend on unrelated input sources")
        XCTAssertEqual(probe.result.blank, probe.result.frames, "A missing conversation still fails the blank check")
        probe.close()
        XCTAssertEqual(CFRunLoopRunInMode(mode, 0.01, false), .finished, "Closing releases the probe's source")
    }
}
