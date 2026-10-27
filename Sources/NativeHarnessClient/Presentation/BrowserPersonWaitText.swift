import Foundation

/// What a browser tab waits on from the person (`BrowserPersonWait`), in words: the panel tab's mark, the task's
/// notification and its sidebar row say it.
enum BrowserPersonWaitText {
    /// One sentence naming the site and what it waits for; `site` is the page's host, if it has one.
    static func describe(_ wait: BrowserPersonWait, site: String?) -> String {
        let site = site.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.string("This page")
        return switch wait.kind {
        case .handoff: L10n.string("The agent handed this tab to you")
        case .passkey: L10n.format("%@ asks for a passkey", site)
        case .signIn: L10n.format("%@ asks you to sign in", site)
        case .permission: L10n.format("%@ asks for a permission", site)
        case .externalApp: L10n.format("%@ asks to open another app", site)
        case .javaScriptDialog: L10n.format("%@ is waiting for an answer to its dialog", site)
        case .fileChooser: L10n.format("%@ is waiting for you to choose a file", site)
        }
    }
}
