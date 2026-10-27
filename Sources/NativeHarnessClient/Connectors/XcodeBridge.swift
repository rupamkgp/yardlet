import Foundation

/// Where this Mac's Xcode keeps `mcpbridge`, the stdio bridge to Xcode's own MCP server (Xcode 26.3
/// and later; Apple, "Giving external agents access to Xcode"). Yardlet runs it as a child of its
/// own, so Xcode asks the person once about Yardlet rather than about each harness, and its tools
/// reach every harness through the Yardlet MCP server like a connector's (docs/CONNECTORS.md, "Apple").
///
/// The bridge talks to the Xcode that is open; Xcode needs a project open, and its Settings →
/// Intelligence → Model Context Protocol must let other agents use its tools (`mcpbridge` says so
/// itself: "Xcode MCP access is disabled; turn it on in Xcode Settings > Intelligence > Model
/// Context Protocol…").
enum XcodeBridge {
    static let defaultExecutable = URL(filePath: "/Applications/Xcode.app/Contents/Developer/usr/bin/mcpbridge")

    /// The bridge of the Xcode `xcode-select` chose, or else of `/Applications/Xcode.app` or
    /// `Xcode-beta.app`; nil on a Mac without an Xcode that has one. It reads paths only: on a Mac
    /// without developer tools, running `xcrun` or `xcode-select` offers to install them.
    static func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                       selectLink: String = "/var/db/xcode_select_link",
                       applications: URL = URL(filePath: "/Applications", directoryHint: .isDirectory),
                       fileManager: FileManager = .default) -> URL? {
        var developerDirectories: [URL] = []
        if let chosen = environment["DEVELOPER_DIR"], !chosen.isEmpty {
            let url = URL(filePath: chosen, directoryHint: .isDirectory)
            developerDirectories.append(url.pathExtension == "app" ? url.appending(path: "Contents/Developer") : url)
        }
        if let selected = try? fileManager.destinationOfSymbolicLink(atPath: selectLink) {
            developerDirectories.append(URL(filePath: selected, directoryHint: .isDirectory))
        }
        for name in ["Xcode.app", "Xcode-beta.app"] {
            developerDirectories.append(applications.appending(path: "\(name)/Contents/Developer", directoryHint: .isDirectory))
        }
        return developerDirectories.lazy
            .map { $0.appending(path: "usr/bin/mcpbridge") }
            .first { fileManager.isExecutableFile(atPath: $0.path(percentEncoded: false)) }
    }

    /// The Xcode app a bridge belongs to (`…/Xcode.app/Contents/Developer/usr/bin/mcpbridge`).
    static func app(of bridge: URL) -> URL? {
        let app = bridge.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }

    /// "27.1", from the Xcode app's Info.plist.
    static func version(of bridge: URL) -> String? {
        guard let app = app(of: bridge),
              let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")) as? [String: Any]
        else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }
}
