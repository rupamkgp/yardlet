import Foundation
import Observation

/// One owner across windows prevents a stale window from overwriting another task's draft.
/// Writes are coalesced while typing and flushed synchronously before shutdown awaits work.
@MainActor
@Observable
final class ComposerDrafts {
    let home = NewTaskDraft()
    let tasks = TaskComposerDraftStore()
    private(set) var storageFailure: StorageFailure?

    enum StorageFailure { case restore, save }

    @ObservationIgnored private let repository: any ComposerDraftRepository
    @ObservationIgnored private let saveDelay: Duration
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var loadFailed = false
    @ObservationIgnored private var isDirty = false
    @ObservationIgnored private var homeEdited = false
    @ObservationIgnored private var editedTasks = Set<UUID>()
    @ObservationIgnored private var retainedSessionIDs: Set<UUID>?

    init(repository: any ComposerDraftRepository = InMemoryComposerDraftRepository(),
         saveDelay: Duration = .milliseconds(250)) {
        self.repository = repository
        self.saveDelay = saveDelay
        restore()
        home.onChange = { [weak self] in
            guard let self else { return }
            self.homeEdited = true
            self.scheduleSave()
        }
        // Automatic defaults are not user edits: a later successful retry can still recover
        // the original home draft and its destination after an initial read failure.
        home.onPreparation = { [weak self] in self?.scheduleSave() }
        tasks.onChange = { [weak self] sessionID in
            guard let self else { return }
            self.editedTasks.insert(sessionID)
            self.scheduleSave()
        }
    }

    /// Called only after a successful index restoration, never for its initially empty state.
    func retainSessions(_ sessionIDs: Set<UUID>) {
        retainedSessionIDs = sessionIDs
        tasks.retainSessions(sessionIDs)
    }

    func remove(for sessionID: UUID) {
        retainedSessionIDs?.remove(sessionID)
        tasks.remove(for: sessionID)
    }

    func retry() {
        if loadFailed { restore() }
        if !loadFailed { persistNow() }
    }

    func persistNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard !loadFailed, isDirty else { return }
        do {
            try repository.save(ComposerDraftSnapshot(home: home.snapshot, tasks: tasks.snapshot))
            isDirty = false
            storageFailure = nil
        } catch {
            storageFailure = .save
        }
    }

    private func restore() {
        do {
            let saved = try repository.load()
            // Retry must preserve input typed after an earlier restore failure.
            if !homeEdited { home.apply(saved.home) }
            tasks.apply(saved.tasks, excluding: editedTasks)
            loadFailed = false
            storageFailure = nil
            if let retainedSessionIDs {
                tasks.retainSessions(retainedSessionIDs.union(editedTasks))
            }
        } catch {
            // Never replace unreadable or newer-format data with an empty snapshot.
            loadFailed = true
            storageFailure = .restore
        }
    }

    private func scheduleSave() {
        isDirty = true
        pendingSave?.cancel()
        guard !loadFailed else { return }
        let delay = saveDelay
        pendingSave = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.persistNow()
        }
    }
}
