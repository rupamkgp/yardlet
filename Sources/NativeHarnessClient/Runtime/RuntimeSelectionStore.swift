import Foundation
import Observation

@MainActor
@Observable
final class RuntimeSelectionStore {
    private(set) var selectedURLs: [HarnessKind: URL]
    private let defaults: UserDefaults

    init(
        defaults: UserDefaults = .yardlet,
        discoversRuntimes: Bool = true,
        loadsPersistedSelections: Bool = true
    ) {
        self.defaults = defaults
        if loadsPersistedSelections {
            for harness in HarnessCatalog.retired { defaults.removeObject(forKey: Self.key(for: harness)) }
        }
        var selections: [HarnessKind: URL] = [:]
        for harness in HarnessCatalog.builtIns.map(\.id) {
            if loadsPersistedSelections,
               let path = defaults.string(forKey: Self.key(for: harness)) {
                let url = URL(filePath: path).standardizedFileURL
                if FileManager.default.isExecutableFile(atPath: url.path(percentEncoded: false)),
                   Self.isCompatibleRuntime(url, for: harness) {
                    selections[harness] = url
                    continue
                }
                // A desktop app that bundles the chosen runtime may have moved it; the choice
                // follows the runtime instead of silently falling back to another install.
                if let moved = RuntimeRelocation.successor(of: url, for: harness),
                   Self.isCompatibleRuntime(moved, for: harness) {
                    selections[harness] = moved
                    defaults.set(moved.path(percentEncoded: false), forKey: Self.key(for: harness))
                    continue
                }
                defaults.removeObject(forKey: Self.key(for: harness))
            }
            if discoversRuntimes, let discovered = Self.discover(harness) {
                selections[harness] = discovered
            }
        }
        self.selectedURLs = selections
    }

    func selectedURL(for harness: HarnessKind) -> URL? {
        guard let url = selectedURLs[harness], Self.isCompatibleRuntime(url, for: harness) else { return nil }
        if FileManager.default.isExecutableFile(atPath: url.path(percentEncoded: false)) { return url }
        // A desktop app replaced the runtime it bundles while Yardlet ran (Claude Desktop deletes the
        // previous version on update): the choice follows it, as on the next launch.
        guard let moved = RuntimeRelocation.successor(of: url, for: harness), Self.isCompatibleRuntime(moved, for: harness) else { return nil }
        return moved
    }

    var connectedDescriptors: [HarnessDescriptor] {
        HarnessCatalog.builtIns.filter { selectedURL(for: $0.id) != nil }
    }

    func select(_ url: URL, for harness: HarnessKind) {
        let standardized = url.standardizedFileURL
        guard Self.isCompatibleRuntime(standardized, for: harness) else {
            return
        }
        selectedURLs[harness] = standardized
        defaults.set(
            standardized.path(percentEncoded: false),
            forKey: Self.key(for: harness)
        )
    }

    private static func key(for harness: HarnessKind) -> String {
        "runtime.\(harness.rawValue).executablePath"
    }

    private static func discover(_ harness: HarnessKind) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [URL]
        if harness == .codex {
            candidates = codexCandidates(home: home)
        } else if harness == .claudeCode {
            candidates = claudeDesktopCandidates(home: home) + [
                home.appending(path: ".local/bin/claude"),
                URL(filePath: "/opt/homebrew/bin/claude"),
                URL(filePath: "/usr/local/bin/claude")
            ] + pathCandidates(named: "claude")
        } else if harness == .museCode {
            // `muse` is a generic executable name. Auto-discover only Meta's
            // documented installer location; a custom binary can still be
            // selected explicitly in Harness Center.
            candidates = [home.appending(path: ".local/bin/muse")]
        } else if let descriptor = HarnessCatalog.descriptor(for: harness) {
            candidates = descriptor.relativeExecutablePaths.map {
                append(relativePath: $0, to: home)
            } + [
                URL(filePath: "/opt/homebrew/bin").appending(path: descriptor.executableName),
                URL(filePath: "/usr/local/bin").appending(path: descriptor.executableName)
            ] + pathCandidates(named: descriptor.executableName)
        } else {
            candidates = []
        }
        return candidates
            .map(\.standardizedFileURL)
            .filter { Self.isCompatibleRuntime($0, for: harness) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false)) }
    }

    /// The legacy `antigravity` executable is an IDE launcher. The supported
    /// structured headless runtime is the official `agy` CLI.
    static func isCompatibleRuntime(_ url: URL, for harness: HarnessKind) -> Bool {
        if harness == .antigravityCLI {
            return url.lastPathComponent == "agy"
        }
        return true
    }

    /// User-managed Codex installs change only when the user updates them, so they are the
    /// default before the ChatGPT-bundled runtime, which the desktop app replaces on its own
    /// schedule. An explicitly saved selection is still honoured over this order.
    static func codexCandidates(
        home: URL,
        searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
    ) -> [URL] {
        [
            home.appending(path: ".local/bin/codex"),
            URL(filePath: "/opt/homebrew/bin/codex"),
            URL(filePath: "/usr/local/bin/codex")
        ] + pathCandidates(named: "codex", searchPath: searchPath)
            + RuntimeRelocation.chatGPTCodexLayouts(inAppAt: URL(filePath: "/Applications/ChatGPT.app"))
    }

    static func claudeDesktopCandidates(
        home: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        let versionsRoot = home
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Application Support", directoryHint: .isDirectory)
            .appending(path: "Claude", directoryHint: .isDirectory)
            .appending(path: "claude-code", directoryHint: .isDirectory)
        return RuntimeRelocation.claudeDesktopLayouts(inVersionsRoot: versionsRoot, fileManager: fileManager)
    }

    private static func pathCandidates(
        named executable: String,
        searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
    ) -> [URL] {
        searchPath
            .split(separator: ":")
            .map { URL(filePath: String($0)).appending(path: executable) }
    }

    private static func append(relativePath: String, to root: URL) -> URL {
        relativePath.split(separator: "/").reduce(root) { partial, component in
            partial.appending(path: String(component))
        }
    }
}
