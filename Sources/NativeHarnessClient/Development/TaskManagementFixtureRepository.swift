#if DEBUG
import Foundation

/// One local write failure for native management-flow review. Relaunch resets all fixture data.
actor TaskManagementFixtureRepository: SessionRepository {
    enum Operation: String { case rename, archive }

    private let storage: InMemorySessionRepository
    private let operation: Operation
    private let sessionID: UUID?
    private let originalTitle: String?
    private var shouldFail = true

    init(sessions: [SessionRecord], failOnce operation: Operation, sessionID: UUID? = nil) {
        storage = InMemorySessionRepository(sessions: sessions)
        self.operation = operation
        let targetID = sessionID ?? sessions.first?.id
        self.sessionID = targetID
        originalTitle = sessions.first { $0.id == targetID }?.title
    }

    func loadSessions() async throws -> [SessionRecord] { try await storage.loadSessions() }

    func upsert(_ session: SessionRecord) async throws {
        if shouldFail, operation == .rename, session.id == sessionID, session.title != originalTitle {
            shouldFail = false
            throw CocoaError(.fileWriteNoPermission)
        }
        try await storage.upsert(session)
    }

    func archive(id: UUID) async throws {
        try await archive(id: id, providerArchived: false)
    }

    func archive(id: UUID, providerArchived: Bool) async throws {
        if shouldFail, operation == .archive, id == sessionID {
            shouldFail = false
            throw CocoaError(.fileWriteNoPermission)
        }
        try await storage.archive(id: id, providerArchived: providerArchived)
    }

    func loadArchivedSessions() async throws -> [ArchivedSessionRecord] {
        try await storage.loadArchivedSessions()
    }

    func unarchive(id: UUID) async throws -> SessionRecord? { try await storage.unarchive(id: id) }

    func discard(id: UUID) async throws { try await storage.discard(id: id) }
}
#endif
