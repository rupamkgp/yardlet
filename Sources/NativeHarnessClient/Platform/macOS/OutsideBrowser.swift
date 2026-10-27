import AppKit

/// A web address in a browser other than Yardlet: "Open in External Browser", and a link Yardlet has no room for
/// (`AppModel.openExternalLinks`). That is the Mac's default browser, or Safari once the person has made Yardlet the
/// default (docs/BROWSER_HOST.md, "Default browser"), so the address never comes back to Yardlet. Any copy of Yardlet
/// counts as Yardlet: a development build shares the installed app's identifier, and Launch Services would hand the
/// address to whichever copy runs. A QA run opens nothing.
@MainActor
enum OutsideBrowser {
    static func open(_ url: URL) {
        guard !QABackground.isOn else {
            NSLog("Yardlet QA: not opening another browser for %@:", url.scheme ?? "?")
            return
        }
        let workspace = NSWorkspace.shared
        guard let handler = workspace.urlForApplication(toOpen: url), isYardlet(handler) else {
            workspace.open(url)
            return
        }
        guard let other = workspace.urlForApplication(withBundleIdentifier: "com.apple.Safari")
            ?? workspace.urlsForApplications(toOpen: url).first(where: { !isYardlet($0) })
        else { return NSSound.beep() }
        workspace.open([url], withApplicationAt: other, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func isYardlet(_ app: URL) -> Bool {
        Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }
}
