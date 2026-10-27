import CSQLite
import XCTest
@testable import NativeHarnessClient

/// "Detach to top level" (the Claude app's row menu item, `XP5vxiZixk`): a task listed under the
/// task it was started from moves to the top level and stays there. Yardlet's index keeps the mark
/// (`SessionRecord.isLineageDetached`, column `lineage_detached`), so no later link from a harness
/// or another app nests it again. Nothing is written outside the index.
@MainActor
final class TaskDetachTests: XCTestCase {
    private let folder = URL(filePath: "/tmp/detach-qa/project", directoryHint: .isDirectory)
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)

    private func task(_ title: String, harness: HarnessKind = .claudeCode, parent: SessionRecord? = nil,
                      minutesAgo: Double, providerSessionID: String? = nil) -> SessionRecord {
        SessionRecord(harness: harness, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/agent"),
                      title: title, titleOrigin: .provider, updatedAt: clock.addingTimeInterval(-minutesAgo * 60),
                      providerSessionID: providerSessionID ?? UUID().uuidString.lowercased(), parentTaskID: parent?.id)
    }

    private func titles(_ rows: [SidebarRow]) -> [String] {
        rows.flatMap(\.rowsWithChildren).map { ($0.isNestedChild ? "  " : "") + $0.title }
    }

    /// Detaching takes the task out of its family to the top level, where its own family follows it.
    /// It is not activity: the task keeps its place in recency order.
    func testDetachingMovesATaskToTheTopLevelWithItsOwnFamily() async throws {
        let parent = task("Plan the release", minutesAgo: 30)
        let child = task("Tag the build", parent: parent, minutesAgo: 10)
        let grandchild = task("Check the tag", parent: child, minutesAgo: 20)
        let store = SessionStore(sessions: [parent, child, grandchild])
        func layoutTitles() -> [String] {
            let groups = [WorkspaceGroup(workspaceURL: folder, sessions: store.sessions)]
            return titles(SidebarProjection.layout(visibleGroups: groups, allGroups: groups, splits: [],
                                                   isFiltering: false).sections[0].rows)
        }
        XCTAssertEqual(layoutTitles(), ["Plan the release", "  Tag the build", "  Check the tag"])

        let detached = try await store.detachFromParent(id: child.id)
        XCTAssertNil(detached?.parentTaskID)
        XCTAssertEqual(detached?.isLineageDetached, true)
        XCTAssertEqual(detached?.updatedAt, child.updatedAt, "Detaching is not activity")
        XCTAssertEqual(store.sessions.first { $0.id == grandchild.id }?.parentTaskID, child.id,
                       "The tasks started from it stay with it")
        XCTAssertEqual(layoutTitles(), ["Tag the build", "  Check the tag", "Plan the release"])
    }

    /// A detached task is never linked again: not by a link pass over imported conversations or
    /// the Claude app's files (`TaskLineage.links`), not by the store, and not when a Codex thread
    /// read names the thread it was forked from. A task that was not detached still links.
    func testADetachedTaskIsNotLinkedAgainByAnImportOrAThreadRead() async throws {
        let parent = task("Parent", minutesAgo: 30)
        var detached = task("Detached", minutesAgo: 20)
        detached.isLineageDetached = true
        let other = task("Never linked", minutesAgo: 10)
        let parents = [detached.providerSessionID!: parent.providerSessionID!,
                       other.providerSessionID!: parent.providerSessionID!]
        XCTAssertEqual(TaskLineage.links(parents: parents, harness: .claudeCode, sessions: [parent, detached, other]),
                       [other.id: parent.id])
        let store = SessionStore(sessions: [parent, detached, other])
        let linked = try await store.linkParents([detached.id: parent.id, other.id: parent.id])
        XCTAssertEqual(linked, [other.id])
        XCTAssertNil(store.sessions.first { $0.id == detached.id }?.parentTaskID)
        XCTAssertEqual(store.sessions.first { $0.id == other.id }?.parentTaskID, parent.id)

        // A Codex thread read: the fork that was detached stays at the top level, another fork links.
        let codexParent = task("Codex parent", harness: .codex, minutesAgo: 9, providerSessionID: "thread-parent")
        var codexDetached = task("Detached fork", harness: .codex, minutesAgo: 8, providerSessionID: "thread-detached")
        codexDetached.isLineageDetached = true
        let codexFork = task("Fork", harness: .codex, minutesAgo: 7, providerSessionID: "thread-fork")
        func state(_ id: String, forkedFrom: String?) -> CodexTaskState {
            var state = CodexTaskState.empty
            var fields: [String: JSONValue] = ["id": .string(id), "turns": .array([])]
            if let forkedFrom { fields["forkedFromId"] = .string(forkedFrom) }
            XCTAssertTrue(CodexTaskReducer().applySnapshot(.object(fields), to: &state))
            return state
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("TaskDetachTests")))
        let sessions = [codexParent, codexDetached, codexFork]
        let model = AppModel(
            store: SessionStore(sessions: sessions, repository: InMemorySessionRepository(sessions: sessions)),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in FakeHarnessAdapter(kind: .codex) },
            initialCodexPresentation: [
                codexDetached.id: state("thread-detached", forkedFrom: "thread-parent"),
                codexFork.id: state("thread-fork", forkedFrom: "thread-parent"),
                codexParent.id: state("thread-parent", forkedFrom: nil),
            ],
            restoresIndexOnLaunch: false)
        for _ in 0..<100 where model.store.sessions.first(where: { $0.id == codexFork.id })?.parentTaskID == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        // Give a link that should not come the same time to arrive.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.store.sessions.first { $0.id == codexFork.id }?.parentTaskID, codexParent.id)
        XCTAssertNil(model.store.sessions.first { $0.id == codexDetached.id }?.parentTaskID)
        await model.shutdown()
    }

    /// The app model's detach changes only the index: the task leaves its family and keeps the mark.
    func testTheModelDetachesThroughTheIndex() async throws {
        let parent = task("Parent", minutesAgo: 30)
        let child = task("Child", parent: parent, minutesAgo: 10)
        let repository = InMemorySessionRepository(sessions: [parent, child])
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("TaskDetachTests")))
        let model = AppModel(
            store: SessionStore(sessions: [parent, child], repository: repository),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in FakeHarnessAdapter(kind: .claudeCode) },
            restoresIndexOnLaunch: false)
        await model.detachFromParent(child)
        let saved = try await repository.loadSessions().first { $0.id == child.id }
        XCTAssertNil(saved?.parentTaskID)
        XCTAssertEqual(saved?.isLineageDetached, true)
        XCTAssertNil(model.bootstrapError)
        await model.shutdown()
    }

    /// The index keeps the mark; an index from before it gains the column with every row intact and
    /// not detached; archiving and restoring keep it; a record decoded without the key is not detached.
    func testTheIndexKeepsTheMarkAndAnOlderIndexGainsItsColumn() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "detach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appending(path: "session-index.sqlite3")
        let parent = task("Parent", minutesAgo: 30)
        let child = task("Linked before detaching existed", parent: parent, minutesAgo: 10)
        // An index written by the build before: links, but no `lineage_detached`.
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path(percentEncoded: false), &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, """
            CREATE TABLE sessions (id TEXT PRIMARY KEY NOT NULL, harness TEXT NOT NULL, workspace_path TEXT NOT NULL,
                runtime_path TEXT NOT NULL, title TEXT NOT NULL, status TEXT NOT NULL, created_at REAL NOT NULL,
                updated_at REAL NOT NULL, provider_session_id TEXT, archived INTEGER NOT NULL DEFAULT 0,
                parent_task_id TEXT);
            INSERT INTO sessions (id, harness, workspace_path, runtime_path, title, status, created_at, updated_at,
                provider_session_id) VALUES ('\(parent.id.uuidString)', 'claude-code', '/tmp/detach-qa/project',
                '/tmp/agent', 'Parent', 'ready', 1, 2, '\(parent.providerSessionID!)');
            INSERT INTO sessions (id, harness, workspace_path, runtime_path, title, status, created_at, updated_at,
                provider_session_id, parent_task_id) VALUES ('\(child.id.uuidString)', 'claude-code',
                '/tmp/detach-qa/project', '/tmp/agent', 'Linked before detaching existed', 'ready', 1, 3,
                '\(child.providerSessionID!)', '\(parent.id.uuidString)');
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        let repository = try SQLiteSessionRepository(databaseURL: database)
        let loaded = try await repository.loadSessions()
        XCTAssertEqual(Set(loaded.map(\.id)), [parent.id, child.id])
        XCTAssertEqual(loaded.first { $0.id == child.id }?.parentTaskID, parent.id, "The old link stays")
        XCTAssertTrue(loaded.allSatisfy { !$0.isLineageDetached }, "Old rows are not detached")
        XCTAssertEqual(try columns(of: database).filter { $0 == "lineage_detached" }, ["lineage_detached"])

        let store = SessionStore(repository: repository)
        try await store.restore()
        try await store.detachFromParent(id: child.id)
        let reopened = try await SQLiteSessionRepository(databaseURL: database).loadSessions()
        let saved = try XCTUnwrap(reopened.first { $0.id == child.id })
        XCTAssertNil(saved.parentTaskID)
        XCTAssertTrue(saved.isLineageDetached)
        XCTAssertEqual(saved.title, "Linked before detaching existed")

        // Archiving and restoring keep the mark.
        try await repository.archive(id: child.id)
        let restored = try await repository.unarchive(id: child.id)
        XCTAssertEqual(restored?.isLineageDetached, true)

        // JSON: kept with the key, not detached without it.
        let encoded = try JSONEncoder().encode(saved)
        XCTAssertTrue(try JSONDecoder().decode(SessionRecord.self, from: encoded).isLineageDetached)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "isLineageDetached")
        let withoutKey = try JSONSerialization.data(withJSONObject: object)
        XCTAssertFalse(try JSONDecoder().decode(SessionRecord.self, from: withoutKey).isLineageDetached)
    }

    private func columns(of database: URL) throws -> [String] {
        var handle: OpaquePointer?
        guard sqlite3_open(database.path(percentEncoded: false), &handle) == SQLITE_OK else { return [] }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA table_info(sessions);", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            names.append(String(cString: sqlite3_column_text(statement, 1)))
        }
        return names
    }
}
