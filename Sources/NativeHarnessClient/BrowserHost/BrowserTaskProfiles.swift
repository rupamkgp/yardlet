import Foundation

/// Which browser profile each task's tabs use (docs/BROWSER_SESSION_ISOLATION.md). With per-task storage,
/// the default, a task's tabs share a profile of its own (cookies, local and session storage, IndexedDB,
/// cache) in a folder the host keeps next to the default profile, `<root cache>/Task-<key>` (Chromium
/// opens a profile on disk only in a direct child of its root cache); the vault's sign-ins stay shared.
/// A new folder starts with the cookies of the task's parent, if it has a folder, else of the default
/// profile. With shared storage every tab uses the default profile, as before.
@MainActor
final class BrowserTaskProfiles {
    /// Settings › General "Keep cookies", as the Claude app's (`launchPreviewStorage`: per session or shared).
    enum Storage: String, CaseIterable, Identifiable, Sendable {
        case perTask
        case shared

        var id: Self { self }

        var title: String {
            switch self {
            case .perTask: L10n.string("Per task")
            case .shared: L10n.string("Shared by all tasks")
            }
        }
    }

    static let storageKey = "Yardlet.browser.cookieStorage"

    /// The browser's root cache, where Chromium keeps the default profile and its own folders too.
    let root: URL
    /// A task profile's folder name is this and its key (the host's `TaskProfiles` names it the same).
    nonisolated static let folderPrefix = "Task-"
    private static let savedFile = "TaskProfiles.json"
    private let defaults: UserDefaults
    /// The task a task was started from (`create_task`): a new task's profile starts from its parent's.
    var parentOf: @MainActor (UUID) -> UUID? = { _ in nil }

    /// Saved in the root cache: tasks whose profile has another key (they took over the new-task
    /// screen's tabs) and the key the new-task screen uses now.
    private struct Saved: Codable {
        var aliases: [String: String] = [:]
        var draftKey: String?
    }
    private var saved: Saved

    init(root: URL, defaults: UserDefaults = .yardlet) {
        self.root = root
        self.defaults = defaults
        saved = (try? Data(contentsOf: root.appending(path: Self.savedFile)))
            .flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
    }

    var storage: Storage {
        get { defaults.string(forKey: Self.storageKey).flatMap(Storage.init(rawValue:)) ?? .perTask }
        set { defaults.set(newValue.rawValue, forKey: Self.storageKey) }
    }

    /// The folder key of a task's profile.
    func key(for session: UUID) -> String {
        if session == TaskWorkspaceStore.draftID { return draftKey }
        return saved.aliases[session.uuidString] ?? session.uuidString
    }

    /// The new-task screen's own key; a task that takes over its tabs takes the key with them.
    private var draftKey: String {
        if let key = saved.draftKey { return key }
        let key = UUID().uuidString
        saved.draftKey = key
        save()
        return key
    }

    func folder(for key: String) -> URL {
        root.appending(path: Self.folderPrefix + key, directoryHint: .isDirectory)
    }

    func folderExists(_ key: String) -> Bool {
        FileManager.default.fileExists(atPath: folder(for: key).path(percentEncoded: false))
    }

    /// What a tab of the task opens in; nil for the default profile (shared storage).
    func profile(for session: UUID) -> BrowserTabProfile? {
        guard storage == .perTask else { return nil }
        let key = key(for: session)
        var seed: String?
        if !folderExists(key), let parent = parentOf(session) {
            let parentKey = self.key(for: parent)
            if folderExists(parentKey) { seed = parentKey }
        }
        return BrowserTabProfile(key: key, seedFrom: seed)
    }

    /// Tabs went from one task to another with their pages (the new-task screen's to the task it started):
    /// a task without a profile yet takes theirs, so its other tabs open beside them.
    func tabsMoved(from source: UUID, to target: UUID) {
        guard target != TaskWorkspaceStore.draftID, saved.aliases[target.uuidString] == nil,
              !folderExists(target.uuidString) else { return }
        saved.aliases[target.uuidString] = key(for: source)
        if source == TaskWorkspaceStore.draftID { saved.draftKey = UUID().uuidString }
        save()
    }

    /// Removes the profile folders no kept task uses (archived and deleted tasks, a new-task screen's
    /// profile it no longer has). Only while the host is not running, which holds the folders open.
    @discardableResult
    func removeFolders(keeping tasks: Set<UUID>) -> [String] {
        let kept = Set(tasks.map(key(for:))).union([draftKey])
        saved.aliases = saved.aliases.filter { tasks.contains(UUID(uuidString: $0.key) ?? UUID()) }
        save()
        // Only task profiles: the root cache also holds the default profile and Chromium's own folders.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []
        var removed: [String] = []
        for name in names where name.hasPrefix(Self.folderPrefix) {
            let key = String(name.dropFirst(Self.folderPrefix.count))
            guard UUID(uuidString: key) != nil, !kept.contains(key) else { continue }
            if (try? FileManager.default.removeItem(at: folder(for: key))) != nil { removed.append(key) }
        }
        forgetMissingProfiles()
        return removed
    }

    /// Chromium lists every profile it opened in the root cache's `Local State` (`profile.info_cache`,
    /// `profile.profiles_order`, `variations_google_groups`) and keeps a profile there after its folder is
    /// gone; task profiles without a folder leave it too, so removed tasks leave nothing behind.
    private func forgetMissingProfiles() {
        let file = root.appending(path: "Local State")
        guard let data = try? Data(contentsOf: file),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var changed = false
        func missing(_ name: String) -> Bool {
            guard name.hasPrefix(Self.folderPrefix), UUID(uuidString: String(name.dropFirst(Self.folderPrefix.count))) != nil
            else { return false }
            return !FileManager.default.fileExists(atPath: root.appending(path: name).path(percentEncoded: false))
        }
        func prune(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] {
                let kept = dictionary.filter { !missing($0.key) }
                if kept.count != dictionary.count { changed = true }
                return kept.mapValues(prune)
            }
            if let array = value as? [Any] {
                let kept = array.filter { !(($0 as? String).map(missing) ?? false) }
                if kept.count != array.count { changed = true }
                return kept.map(prune)
            }
            return value
        }
        let pruned = prune(state)
        guard changed, let output = try? JSONSerialization.data(withJSONObject: pruned) else { return }
        try? output.write(to: file, options: .atomic)
    }

    private func save() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: root.appending(path: Self.savedFile), options: .atomic)
    }
}
