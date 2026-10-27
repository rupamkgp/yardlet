import Foundation

/// Writes the transcript reading snapshots a detached task shows. A streaming task publishes its
/// transcript many times a second; only the newest snapshot of a burst is written, once the
/// burst is `delay` old, and encoding and writing happen off the main thread. Writes and
/// removals for a task keep their order, and `saveNow`, `remove` and `flush` return only once
/// the repository holds the result.
@MainActor
final class TranscriptSnapshotWriter {
    private struct Repository: @unchecked Sendable {
        let base: any TranscriptRepository
    }

    private let repository: Repository
    private let queue = DispatchQueue(label: "Yardlet.TranscriptSnapshots", qos: .utility)
    private let delay: Duration
    private var pending: [UUID: [TranscriptEntry]] = [:]
    private var timers: [UUID: Task<Void, Never>] = [:]

    init(repository: any TranscriptRepository, delay: Duration = .seconds(1)) {
        self.repository = Repository(base: repository)
        self.delay = delay
    }

    func load(for sessionID: UUID) -> [TranscriptEntry] {
        let repository = repository
        return queue.sync { repository.base.load(for: sessionID) }
    }

    /// Keeps `entries` as the task's next snapshot and writes it once the current burst ends.
    func scheduleSave(_ entries: [TranscriptEntry], for sessionID: UUID) {
        pending[sessionID] = entries
        guard timers[sessionID] == nil else { return }
        let delay = delay
        timers[sessionID] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.writePending(for: sessionID)
        }
    }

    /// Writes `entries` in the background now, replacing any snapshot still waiting.
    func saveSoon(_ entries: [TranscriptEntry], for sessionID: UUID) {
        cancelPending(for: sessionID)
        let repository = repository
        queue.async { repository.base.save(entries, for: sessionID) }
    }

    /// Writes `entries` and returns once they are saved, replacing any snapshot still waiting.
    func saveNow(_ entries: [TranscriptEntry], for sessionID: UUID) {
        cancelPending(for: sessionID)
        let repository = repository
        queue.sync { repository.base.save(entries, for: sessionID) }
    }

    func remove(for sessionID: UUID) {
        cancelPending(for: sessionID)
        let repository = repository
        queue.sync { repository.base.remove(for: sessionID) }
    }

    /// Removes the snapshot in the background, replacing any snapshot still waiting.
    func removeSoon(for sessionID: UUID) {
        cancelPending(for: sessionID)
        let repository = repository
        queue.async { repository.base.remove(for: sessionID) }
    }

    /// Writes every snapshot still waiting and returns once all writes are done.
    func flush() {
        for id in Array(pending.keys) { writePending(for: id) }
        queue.sync {}
    }

    /// `flush()` for quitting: every waiting snapshot is written, and this returns once all writes
    /// are done, without holding the main thread while they are encoded and written. Long
    /// conversations take a while to write, and a main thread held that long reads as not
    /// responding.
    func flushed() async {
        for id in Array(pending.keys) { writePending(for: id) }
        let queue = queue
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { done.resume() }
        }
    }

    private func writePending(for sessionID: UUID) {
        timers.removeValue(forKey: sessionID)?.cancel()
        guard let entries = pending.removeValue(forKey: sessionID) else { return }
        let repository = repository
        queue.async { repository.base.save(entries, for: sessionID) }
    }

    private func cancelPending(for sessionID: UUID) {
        timers.removeValue(forKey: sessionID)?.cancel()
        pending.removeValue(forKey: sessionID)
    }
}
