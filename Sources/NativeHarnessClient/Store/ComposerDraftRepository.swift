import Foundation

struct TaskDraftSnapshot: Codable, Equatable {
    var text = ""
    var attachments: [CodexUserInput] = []
    var editState: ConversationEditState? = nil
    /// A Claude composer left in bash mode. Absent, as in drafts saved before it existed, is off.
    var isBashMode: Bool? = nil
    /// Diff comments waiting for the next message. Absent, as in drafts saved before they existed, is none.
    var diffComments: [DiffComment]? = nil
    /// Browser comments waiting for the next message. Absent, as in drafts saved before they existed, is none.
    var browserComments: [BrowserComment]? = nil
    var isEmpty: Bool {
        text.isEmpty && attachments.isEmpty && editState == nil && (diffComments ?? []).isEmpty
            && (browserComments ?? []).isEmpty
    }
}

struct HomeDraftSnapshot: Codable, Equatable {
    var text = ""
    var workspaceURL: URL?
    var projectID: UUID?
    /// The next task starts as a chat, with no folder chosen. Absent, as in drafts saved before
    /// it existed, it starts in the chosen folder.
    var startsChat: Bool?
    var harness: HarnessKind?
    var hasPreparedWorkspace = false
    var connectionSelection: [HarnessKind: String]?
    var attachments: [CodexUserInput]?
    /// Projects whose new tasks were last started in a new worktree rather than locally.
    var worktreeProjectIDs: Set<UUID>?
    /// The model and effort last chosen for new tasks, per harness.
    var modelChoices: [HarnessKind: NewTaskModelChoice]?
    /// The suggested task whose Start opened the draft. Absent, as in drafts saved before it
    /// existed, the draft is the person's own.
    var suggestion: NewTaskSuggestionOrigin?
}

/// A model and effort chosen on the new-task screen, in the harness's own values. The new task
/// keeps it as its own choice, so its first turn already runs on it.
struct NewTaskModelChoice: Codable, Equatable, Sendable {
    /// Nil when only an effort was chosen, which leaves the model to the account's settings.
    var model: String?
    var effort: String?
    /// Codex's service tier (Fast) chosen with the model.
    var serviceTier: String?
    /// Claude Code's permission mode, which the task launches in, or Antigravity's, which its
    /// first run takes. Absent, as in drafts saved before it existed, the task starts in the
    /// harness's default mode as every task does.
    var permissionMode: String?

    init(model: String?, effort: String? = nil, serviceTier: String? = nil, permissionMode: String? = nil) {
        self.model = model
        self.effort = effort
        self.serviceTier = serviceTier
        self.permissionMode = permissionMode
    }

    init(_ selection: CodexModelSelection) {
        self.init(model: selection.model, effort: selection.reasoningEffort, serviceTier: selection.serviceTier)
    }

    /// Codex chooses a model and its effort as one pair.
    var codexSelection: CodexModelSelection? {
        model.map { CodexModelSelection(model: $0, reasoningEffort: effort, serviceTier: serviceTier) }
    }

    /// The task options a new task of this harness starts with: the keys the task's own model
    /// menu keeps its choice under.
    func providerOptions(for harness: HarnessKind) -> [String: String] {
        switch harness {
        case .claudeCode:
            var options: [String: String] = [:]
            if let model { options[ClaudeLaunchOption.model] = model }
            if let effort { options[ClaudeLaunchOption.effort] = effort }
            if let permissionMode { options[ClaudeLaunchOption.permissionMode] = permissionMode }
            return options
        case .codex:
            return codexSelection?.storedValue.map { [CodexModelSelection.storageKey: $0] } ?? [:]
        case .antigravityCLI:
            var options: [String: String] = [:]
            if let model { options[StructuredHeadlessOptionID.model] = model }
            if let effort { options[StructuredHeadlessOptionID.reasoningEffort] = effort }
            if let permissionMode { options[StructuredHeadlessOptionID.permissionMode] = permissionMode }
            return options
        default:
            return [:]
        }
    }
}

/// Only unsent user input and its destination belong here. Runtime handles, credentials,
/// pending submissions and transient error messages are deliberately absent.
struct ComposerDraftSnapshot: Codable, Equatable {
    var version = 1
    var home = HomeDraftSnapshot()
    var tasks: [UUID: TaskDraftSnapshot] = [:]
}

@MainActor
protocol ComposerDraftRepository {
    func load() throws -> ComposerDraftSnapshot
    func save(_ snapshot: ComposerDraftSnapshot) throws
}

@MainActor
final class InMemoryComposerDraftRepository: ComposerDraftRepository {
    var snapshot = ComposerDraftSnapshot()
    func load() -> ComposerDraftSnapshot { snapshot }
    func save(_ snapshot: ComposerDraftSnapshot) { self.snapshot = snapshot }
}

struct FileComposerDraftRepository: ComposerDraftRepository {
    let directoryURL: URL
    var fileURL: URL { directoryURL.appending(path: "drafts.json") }

    func load() throws -> ComposerDraftSnapshot {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return ComposerDraftSnapshot()
        }
        struct Header: Decodable { let version: Int }
        guard try JSONDecoder().decode(Header.self, from: data).version == 1 else {
            throw CocoaError(.coderReadCorrupt)
        }
        return try JSONDecoder().decode(ComposerDraftSnapshot.self, from: data)
    }

    func save(_ snapshot: ComposerDraftSnapshot) throws {
        let manager = FileManager.default
        // A private directory also protects the temporary file used for atomic replacement.
        try manager.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
