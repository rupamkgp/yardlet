import AppKit
import XCTest
@testable import NativeHarnessClient

final class BrowserURLPolicyTests: XCTestCase {
    func testOnlyTheAllowedSchemesPass() {
        for url in ["https://example.com", "HTTP://127.0.0.1:3000/", "file:///tmp/a.html", "about:blank", "data:text/html,hi"] {
            XCTAssertTrue(BrowserURLPolicy.isAllowed(url), url)
        }
        for url in ["javascript:alert(1)", "chrome://version", "devtools://devtools", "x-app://open", "blob:https://a.test/1",
                    "mailto:a@b.test", "not a url", ""] {
            XCTAssertFalse(BrowserURLPolicy.isAllowed(url), url)
        }
    }

    func testAddressInputResolves() throws {
        XCTAssertEqual(try BrowserURLPolicy.resolve("example.com/path"), "https://example.com/path")
        XCTAssertEqual(try BrowserURLPolicy.resolve("localhost:3000"), "http://localhost:3000")
        XCTAssertEqual(try BrowserURLPolicy.resolve("127.0.0.1:8080/x"), "http://127.0.0.1:8080/x")
        XCTAssertEqual(try BrowserURLPolicy.resolve("  http://example.com  "), "http://example.com")
        XCTAssertEqual(try BrowserURLPolicy.resolve("/tmp/page.html"), "file:///tmp/page.html")
        XCTAssertEqual(try BrowserURLPolicy.resolve("about:blank"), "about:blank")
        XCTAssertThrowsError(try BrowserURLPolicy.resolve("javascript:alert(1)")) {
            XCTAssertEqual($0 as? BrowserURLPolicy.AddressError, .blockedScheme("javascript"))
        }
        XCTAssertThrowsError(try BrowserURLPolicy.resolve("two words"))
        XCTAssertThrowsError(try BrowserURLPolicy.resolve(" "))
    }

    func testAddressFieldSearchesWhatIsNoAddress() throws {
        let search = { "https://www.google.com/search?q=" + $0 }
        for (typed, expected) in [("two words", search("two%20words")), ("yardlet", search("yardlet")), ("1.5", search("1.5")), ("c++ & go", search("c%2B%2B%20%26%20go")),
                                  ("날씨 서울", search("%EB%82%A0%EC%94%A8%20%EC%84%9C%EC%9A%B8")), ("?example.com", search("example.com")),
                                  ("example.com/path", "https://example.com/path"), ("localhost", "http://localhost"),
                                  ("localhost:3000", "http://localhost:3000"), ("192.168.0.10", "https://192.168.0.10"),
                                  ("네이버.kr", "https://네이버.kr"), ("https://a.test/x y", "https://a.test/x y"), ("~/a.html", try BrowserURLPolicy.resolve("~/a.html"))] {
            XCTAssertEqual(try BrowserURLPolicy.addressFieldURL(typed), expected, typed)
        }
        XCTAssertThrowsError(try BrowserURLPolicy.addressFieldURL("javascript:alert(1)"))
        XCTAssertThrowsError(try BrowserURLPolicy.addressFieldURL("?"))
    }
}

final class BrowserKeyCodeTests: XCTestCase {
    func testPhysicalKeysMapToChromiumKeyCodes() {
        XCTAssertEqual(BrowserKeyCodes.windowsKeyCode(forMacKeyCode: 0x00), 0x41)  // A
        XCTAssertEqual(BrowserKeyCodes.windowsKeyCode(forMacKeyCode: 0x1D), 0x30)  // 0
        XCTAssertEqual(BrowserKeyCodes.windowsKeyCode(forMacKeyCode: 0x2F), 0xBE)  // period
        XCTAssertEqual(BrowserKeyCodes.windowsKeyCode(forMacKeyCode: 0x24), 0x0D)  // Return
        XCTAssertEqual(BrowserKeyCodes.windowsKeyCode(forMacKeyCode: 0x7E), 0x26)  // Up
        XCTAssertEqual(BrowserKeyCodes.windowsKeyCode(forMacKeyCode: 0x7A), 0x70)  // F1
        XCTAssertEqual(BrowserKeyCodes.windowsKeyCode(forMacKeyCode: 0x5A), 0x83)  // F20
        XCTAssertEqual(BrowserKeyCodes.windowsKeyCode(forMacKeyCode: 0x38), 0x10)  // Shift
        XCTAssertEqual(BrowserKeyCodes.windowsKeyCode(forMacKeyCode: 0x37), 0x5B)  // Command
        XCTAssertEqual(BrowserKeyCodes.windowsKeyCode(forMacKeyCode: 0x52), 0x60)  // Keypad 0
        XCTAssertEqual(BrowserKeyCodes.windowsKeyCode(forMacKeyCode: 0x68), 0x15)  // Han/Yeong (Kana)
        XCTAssertEqual(BrowserKeyCodes.inputMethodProcessKey, 229)
        XCTAssertEqual(Set(BrowserKeyCodes.windowsKeyCodes.keys).count, BrowserKeyCodes.windowsKeyCodes.count)
    }

    @MainActor
    func testModifierKeysBecomeKeyPressesAndReleases() throws {
        let view = BrowserHostView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        var sent: [BrowserHostCommand] = []
        view.tabID = 1
        view.sendCommand = { sent.append($0) }
        for (down, flags) in [(true, CGEventFlags.maskShift), (false, [])] {
            let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0x3C, keyDown: down))
            event.type = .flagsChanged
            event.flags = flags
            view.flagsChanged(with: try XCTUnwrap(NSEvent(cgEvent: event)))
        }
        guard sent.count == 2, case .key(_, let press) = sent[0], case .key(_, let release) = sent[1] else {
            return XCTFail("expected two key commands, got \(sent)")
        }
        XCTAssertEqual(press.kind, .rawDown)
        XCTAssertEqual(release.kind, .up)
        XCTAssertEqual(press.windowsKeyCode, 0x10)
        XCTAssertTrue(press.modifiers.contains(.isRight))
    }
}
