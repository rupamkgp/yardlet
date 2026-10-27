import Foundation

/// Keeps the app-local Codex cards each task has saved in memory. A streaming Codex task merges
/// them into every timeline state it publishes; reading and decoding them from storage each
/// time cost the main thread more than anything else the stream did. Every read and write of
/// the app model goes through this cache, so it always matches what is stored.
final class CachedCodexTimelineItemRepository: CodexTimelineItemRepository {
    private let base: any CodexTimelineItemRepository
    private var items: [UUID: [CodexPersistedTimelineItem]] = [:]

    init(_ base: any CodexTimelineItemRepository) {
        self.base = base
    }

    func load(for sessionID: UUID) -> [CodexPersistedTimelineItem] {
        if let cached = items[sessionID] { return cached }
        let loaded = base.load(for: sessionID)
        items[sessionID] = loaded
        return loaded
    }

    func save(_ items: [CodexPersistedTimelineItem], for sessionID: UUID) {
        self.items[sessionID] = items
        base.save(items, for: sessionID)
    }

    func remove(for sessionID: UUID) {
        items[sessionID] = []
        base.remove(for: sessionID)
    }
}

/// The same in-memory copy for the Codex approvals and questions a task has saved.
final class CachedCodexPendingServerRequestRepository: CodexPendingServerRequestRepository {
    private let base: any CodexPendingServerRequestRepository
    private var requests: [UUID: [CodexPendingServerRequest]] = [:]

    init(_ base: any CodexPendingServerRequestRepository) {
        self.base = base
    }

    func load(for sessionID: UUID) -> [CodexPendingServerRequest] {
        if let cached = requests[sessionID] { return cached }
        let loaded = base.load(for: sessionID)
        requests[sessionID] = loaded
        return loaded
    }

    func save(_ requests: [CodexPendingServerRequest], for sessionID: UUID) {
        self.requests[sessionID] = requests
        base.save(requests, for: sessionID)
    }

    func remove(for sessionID: UUID) {
        requests[sessionID] = []
        base.remove(for: sessionID)
    }
}
