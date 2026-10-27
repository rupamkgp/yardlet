import Foundation

/// The earlier version Yardlet runs in place of a harness install whose new version failed
/// Yardlet's check after an update (product document 13.22). The install itself stays as its
/// updater left it; only the runtime Yardlet starts for it changes, so turning automatic updates
/// off, or removing Yardlet, leaves the person's install as it is. Read when an adapter is made,
/// from any thread.
final class CLIRuntimeOverrides: @unchecked Sendable {
    struct Entry: Codable, Equatable, Sendable {
        /// The selected runtime path that a task records (often a link, such as `/opt/homebrew/bin/codex`).
        var launcher: String
        /// Where that path led when the new version failed.
        var installed: String
        /// The earlier version's executable Yardlet runs instead.
        var target: String
        var failedVersion: String
        var version: String
    }

    static let shared = CLIRuntimeOverrides(defaults: .yardlet)
    static let defaultsKey = "cliUpdate.runtimeOverrides"

    private let lock = NSLock()
    private let defaults: UserDefaults?
    private var entries: [String: Entry]

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        entries = defaults?.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    func entry(for harness: HarnessKind) -> Entry? {
        lock.withLock { entries[harness.rawValue] }
    }

    func set(_ entry: Entry?, for harness: HarnessKind) {
        lock.withLock {
            entries[harness.rawValue] = entry
            persist()
        }
    }

    func removeAll() {
        lock.withLock {
            entries = [:]
            persist()
        }
    }

    /// The runtime to start for `requested`: the earlier version while one is held for this
    /// install and its file is still there, otherwise `requested` itself.
    func executable(for harness: HarnessKind, requested: URL) -> URL {
        guard let entry = entry(for: harness),
              FileManager.default.isExecutableFile(atPath: entry.target) else { return requested }
        let standardized = requested.standardizedFileURL
        let path = standardized.path(percentEncoded: false)
        guard path == entry.launcher
            || standardized.resolvingSymlinksInPath().path(percentEncoded: false) == entry.installed else { return requested }
        return URL(filePath: entry.target)
    }

    /// The folder under Yardlet's storage where copies of earlier versions are kept.
    static let copiesFolderName = "cli-previous"

    /// Whether `url` is one of Yardlet's copies of an earlier CLI version.
    static func isYardletCopy(_ url: URL) -> Bool {
        url.standardizedFileURL.path(percentEncoded: false)
            .contains("/\(YardletProduct.storageDirectoryName)/\(copiesFolderName)/")
    }

    private func persist() {
        guard let defaults else { return }
        if entries.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
