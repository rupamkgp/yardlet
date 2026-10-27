import Foundation

/// History navigation is app-owned intent, not provider state. Keeping it in a small
/// Codex-only repository lets a restored task reopen the selected result without adding
/// Codex fields to the shared SessionRecord contract or waking a provider at launch.
protocol CodexHistorySelectionRepository {
    func load(for sessionID: UUID) -> CodexHistorySearchSelection?
    func save(_ selection: CodexHistorySearchSelection, for sessionID: UUID)
    func remove(for sessionID: UUID)
}

struct UserDefaultsCodexHistorySelectionRepository: CodexHistorySelectionRepository {
    let defaults: UserDefaults
    let keyPrefix: String

    init(
        defaults: UserDefaults = .yardlet,
        keyPrefix: String = "NativeHarnessClient.codexHistorySelection."
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    func load(for sessionID: UUID) -> CodexHistorySearchSelection? {
        guard let data = defaults.data(forKey: keyPrefix + sessionID.uuidString) else { return nil }
        return try? JSONDecoder().decode(CodexHistorySearchSelection.self, from: data)
    }

    func save(_ selection: CodexHistorySearchSelection, for sessionID: UUID) {
        guard let data = try? JSONEncoder().encode(selection) else { return }
        defaults.set(data, forKey: keyPrefix + sessionID.uuidString)
    }

    func remove(for sessionID: UUID) {
        defaults.removeObject(forKey: keyPrefix + sessionID.uuidString)
    }
}
