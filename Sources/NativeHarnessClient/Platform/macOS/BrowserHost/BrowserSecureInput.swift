import AppKit
import Carbon

/// What a browser view turns on while the page's password field has the keyboard, as Safari does
/// (WebKit's `WebViewImpl::updateSecureInputState`; Chrome's `ScopedPasswordInputEnabler` does the same):
/// secure keyboard entry, so no other process can read the keys, and only Roman input sources in the
/// view's own input context, so an input method such as Korean cannot compose a password. The input
/// source limit belongs to that context and leaves with it; secure keyboard entry is the process's, and
/// a view turns it off exactly as many times as it turned it on.
@MainActor
protocol BrowserSecureInputSystem: AnyObject {
    func isKeyWindow(_ window: NSWindow) -> Bool
    func setSecureEventInput(_ isEnabled: Bool)
    func setRomanInputSourcesOnly(_ isOnly: Bool, in context: NSTextInputContext?)
}

@MainActor
enum BrowserSecureInput {
    /// The system a new browser view uses. A QA app (`QABackground`) and the tests record instead, so
    /// neither changes the person's keyboard or input source.
    static var system: any BrowserSecureInputSystem = {
#if DEBUG
        if QABackground.isOn || NSClassFromString("XCTestCase") != nil { return BrowserSecureInputRecorder() }
#endif
        return MacSecureInputSystem()
    }()
}

@MainActor
final class MacSecureInputSystem: BrowserSecureInputSystem {
    func isKeyWindow(_ window: NSWindow) -> Bool { window.isKeyWindow }

    func setSecureEventInput(_ isEnabled: Bool) {
        // Carbon counts these for the process.
        _ = isEnabled ? EnableSecureEventInput() : DisableSecureEventInput()
    }

    func setRomanInputSourcesOnly(_ isOnly: Bool, in context: NSTextInputContext?) {
        context?.allowedInputSourceLocales = isOnly ? [NSAllRomanInputSourcesLocaleIdentifier] : nil
    }
}

#if DEBUG
/// What browser views would turn on, for tests and QA, which must not change the person's keyboard or
/// input source. A QA app never becomes active, so its windows count as key unless a check says not.
@MainActor
final class BrowserSecureInputRecorder: BrowserSecureInputSystem {
    var windowIsKey = true
    /// Secure keyboard entry's count: one per view that has it on.
    private(set) var secureEventInputCount = 0
    /// The calls in order, `secure on`, `roman only`, `all sources` and `secure off`.
    private(set) var calls: [String] = []

    func isKeyWindow(_ window: NSWindow) -> Bool { windowIsKey }

    func setSecureEventInput(_ isEnabled: Bool) {
        secureEventInputCount += isEnabled ? 1 : -1
        calls.append(isEnabled ? "secure on" : "secure off")
    }

    func setRomanInputSourcesOnly(_ isOnly: Bool, in context: NSTextInputContext?) {
        calls.append(isOnly ? "roman only" : "all sources")
    }
}
#endif
