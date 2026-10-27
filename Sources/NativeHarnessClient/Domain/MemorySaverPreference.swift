import Foundation

/// Whether Yardlet's memory saver is on (Settings › General "Memory saver"): idle tasks' browser tabs are discarded
/// (`BrowserMemorySaver`) and their harness processes end until the next message (`HarnessMemorySaver`). On unless the
/// person turned it off; turning it off brings the discarded tabs back and ends nothing more.
enum MemorySaverPreference {
    static let key = "Yardlet.memorySaver"

    static func isOn(in defaults: UserDefaults = .yardlet) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}
