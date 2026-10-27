#if DEBUG
import AppKit

/// QA without screen or accessibility access: with `YARDLET_QA_TAB_KEYS=<file>`, a fixture launch
/// lists the menu bar's key equivalents (and any two items sharing one), then sends the menu bar
/// the key events a keyboard sends for the tab and split keys and writes what each did.
@MainActor
enum WindowTabsKeyQA {
    static func runIfRequested(model: AppModel) {
        guard let path = ProcessInfo.processInfo.environment["YARDLET_QA_TAB_KEYS"], !path.isEmpty else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            var lines: [String] = []
            let window = NSApp.windows.first { $0.canBecomeMain && $0.isVisible }
            window?.makeKey()
            try? await Task.sleep(for: .milliseconds(500))
            lines.append("key window: \(NSApp.keyWindow === window), active: \(NSApp.isActive)")
            var seen: [String: String] = [:]
            @MainActor func walk(_ menu: NSMenu, _ prefix: String) {
                for item in menu.items {
                    let name = prefix + item.title
                    if let submenu = item.submenu { walk(submenu, name + " › ") }
                    guard !item.keyEquivalent.isEmpty else { continue }
                    let key = describe(item.keyEquivalent, item.keyEquivalentModifierMask)
                    lines.append("menu \(key) \(name) enabled=\(item.isEnabled)")
                    if let other = seen[key] { lines.append("DUPLICATE \(key): \(other) | \(name)") }
                    seen[key] = name
                }
            }
            if let menu = NSApp.mainMenu { walk(menu, "") }
            lines.append("start: \(state(model))")
            let presses: [(String, String, String, UInt16, NSEvent.ModifierFlags)] = [
                ("⌃Tab", "\t", "\t", 48, [.control]),
                ("⌃⇧Tab", "\u{19}", "\u{19}", 48, [.control, .shift]),
                ("⌘T", "t", "t", 17, [.command]),
                ("⌘W", "w", "w", 13, [.command]),
                ("⌘⇧T", "T", "T", 17, [.command, .shift]),
                ("⌘W", "w", "w", 13, [.command]),
                ("⌃⇧Tab", "\u{19}", "\u{19}", 48, [.control, .shift]),
                ("⌘⇧D", "D", "D", 2, [.command, .shift]),
                ("⌥⌘←", "\u{F702}", "\u{F702}", 123, [.command, .option, .numericPad, .function]),
                ("⌃⌘W", "\u{17}", "w", 13, [.command, .control]),
                ("⌃⌘W", "\u{17}", "w", 13, [.command, .control])
            ]
            for (name, characters, ignoring, keyCode, flags) in presses {
                guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                                   timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window?.windowNumber ?? 0, context: nil,
                                                   characters: characters, charactersIgnoringModifiers: ignoring,
                                                   isARepeat: false, keyCode: keyCode) else { continue }
                let handled = NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
                try? await Task.sleep(for: .milliseconds(400))
                lines.append("\(name) handled=\(handled) → \(state(model))")
            }
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    nonisolated private static func describe(_ key: String, _ mask: NSEvent.ModifierFlags) -> String {
        var text = ""
        if mask.contains(.control) { text += "⌃" }
        if mask.contains(.option) { text += "⌥" }
        if mask.contains(.shift) { text += "⇧" }
        if mask.contains(.command) { text += "⌘" }
        switch key {
        case "\t": return text + "Tab"
        case "\u{19}": return text + "⇧Tab"
        case "\u{F702}": return text + "←"
        case "\u{F703}": return text + "→"
        case "\u{F700}": return text + "↑"
        case "\u{F701}": return text + "↓"
        default: return text + key.uppercased()
        }
    }

    private static func state(_ model: AppModel) -> String {
        func name(_ item: WindowItem) -> String {
            switch item {
            case .home: return "home"
            case let .session(id): return model.store.sessions.first { $0.id == id }?.title ?? "?"
            case let .split(id):
                let split = model.splits.splits.first { $0.id == id }
                return "split(\(split?.panes.map { pane in pane.sessionID.flatMap { id in model.store.sessions.first { $0.id == id }?.title } ?? "empty" }.joined(separator: "|") ?? "?"))"
            }
        }
        let tabs = model.splits.tabs.map { ($0 == model.splits.selection ? "*" : "") + name($0) }
        let focused = model.store.selectedSession?.title ?? "none"
        return "tabs=[\(tabs.joined(separator: ", "))] focused=\(focused)"
    }
}
#endif
