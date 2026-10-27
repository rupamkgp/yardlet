import Foundation
import XCTest
@testable import NativeHarnessClient

/// A file's related tasks: what each task's calls read and edited, kept in Yardlet's
/// own folder and read on from where the last question left it; one file whichever checkout of its
/// repository a call named it in; and a task's conversation read back to the call before it is shown.
@MainActor
final class FileTasksTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "file-tasks-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - A Claude Code transcript's calls

    func testATranscriptsCallsAreReadOnFromWhereTheLastReadingStopped() throws {
        let at = "2026-10-26T09:00:00.000Z"
        var file = Data()
        file += Self.line(Self.call("e-1", "Edit", "/work/app/docs/plan.md", at: at))
        file += Self.line(Self.result("e-1", failed: false))
        // A read of a file that is not there failed, and a subagent's own edit is not the task's.
        file += Self.line(Self.call("r-1", "Read", "/work/app/missing.md", at: at))
        file += Self.line(Self.result("r-1", failed: true))
        file += Self.line(Self.call("s-1", "Write", "/work/app/sub.md", at: at, sidechain: true))
        file += Self.line(Self.call("r-2", "Read", "/work/app/README.md", at: at))
        file += Self.line(Self.result("r-2", failed: false))
        // A call whose line is still being written is read next time.
        let pending = Self.line(Self.call("w-1", "Write", "/work/app/new.md", at: at))
        file += pending.prefix(40)

        var reads: [Int64] = []
        func scan(_ data: Data, inode: UInt64 = 7, previous: FileTouches) throws -> FileTouches {
            try ClaudeFileTouchScanner.scan(providerSessionID: "s", device: 1, inode: inode, size: Int64(data.count),
                                            previous: previous) { offset, count in
                reads.append(offset)
                return data.subdata(in: Int(offset)..<min(data.count, Int(offset) + count))
            }
        }
        let first = try scan(file, previous: FileTouches())
        XCTAssertEqual(first.files.keys.sorted(), ["/work/app/README.md", "/work/app/docs/plan.md"])
        XCTAssertEqual(first.files["/work/app/docs/plan.md"]?.edit?.callID, "e-1")
        XCTAssertNil(first.files["/work/app/docs/plan.md"]?.read)
        XCTAssertEqual(first.files["/work/app/README.md"]?.read?.callID, "r-2")
        let firstEnd = try XCTUnwrap(first.claudeScan?.offset)
        XCTAssertEqual(Int(firstEnd), file.count - 40, "the line still being written is left")

        // The call's line is finished; its result has not come yet, so it counts while it runs.
        file += pending.dropFirst(40)
        reads = []
        let second = try scan(file, previous: first)
        XCTAssertEqual(reads.first, firstEnd, "only what was appended is read")
        XCTAssertNil(second.files["/work/app/new.md"])
        XCTAssertEqual(second.marksWithOpenCalls["/work/app/new.md"]?.edit?.callID, "w-1")
        file += Self.line(Self.result("w-1", failed: false))
        let third = try scan(file, previous: second)
        XCTAssertEqual(third.files["/work/app/new.md"]?.edit?.callID, "w-1")
        XCTAssertTrue(third.openCalls.isEmpty)

        // Another file under the name (a new inode) is read from its start.
        reads = []
        _ = try scan(file, inode: 8, previous: third)
        XCTAssertEqual(reads.first, 0)
    }

    // MARK: - One file in every checkout

    func testTheSameFileInARepositoryAndItsWorktreesIsOneFile() throws {
        let repository = root.appending(path: "app")
        try FileManager.default.createDirectory(at: repository.appending(path: ".git/worktrees/linked"),
                                                withIntermediateDirectories: true)
        try "../..\n".write(to: repository.appending(path: ".git/worktrees/linked/commondir"), atomically: true, encoding: .utf8)
        let linked = root.appending(path: "linked")
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try "gitdir: \(repository.path(percentEncoded: false))/.git/worktrees/linked\n"
            .write(to: linked.appending(path: ".git"), atomically: true, encoding: .utf8)
        let made = root.appending(path: "yardlet-worktrees/app/feature")
        var resolver = FileRepositoryResolver(knownWorktrees: [made.path(percentEncoded: false): repository.path(percentEncoded: false)])

        let main = resolver.key(for: repository.appending(path: "docs/NOTES.md").path(percentEncoded: false))
        XCTAssertEqual(main, FileRepositoryKey(repository: repository.path(percentEncoded: false), path: "docs/NOTES.md"))
        for path in [
            linked.appending(path: "docs/NOTES.md"),
            // Claude Code's worktree, removed since.
            repository.appending(path: ".claude/worktrees/gone/docs/NOTES.md"),
            // A worktree a task was made in, removed since.
            made.appending(path: "docs/NOTES.md")
        ] {
            XCTAssertEqual(resolver.key(for: path.path(percentEncoded: false)), main, path.path(percentEncoded: false))
        }
        XCTAssertNotEqual(resolver.key(for: repository.appending(path: "docs/GUIDE.md").path(percentEncoded: false)), main)
        XCTAssertEqual(resolver.key(for: "/elsewhere/notes.md"), FileRepositoryKey(repository: nil, path: "/elsewhere/notes.md"))
    }

    // MARK: - The app

    func testAFilesTasksAreTheTasksThatEditedOrReadItAndOpenWhereTheyDid() async throws {
        let repository = root.appending(path: "app")
        try FileManager.default.createDirectory(at: repository.appending(path: ".git"), withIntermediateDirectories: true)
        let worktree = repository.appending(path: ".claude/worktrees/feature")
        let other = root.appending(path: "other")
        try FileManager.default.createDirectory(at: other.appending(path: ".git"), withIntermediateDirectories: true)
        let config = root.appending(path: "config")

        // The editor's call is far back in a long conversation, past the newest part a task first reads.
        let editor = try task("Home redesign", in: worktree, config: config, id: "8F7C2A51-3E0B-4C47-9C2D-6A1B0E4F9D31",
                              call: ("toolu_edit", "Edit", worktree.appending(path: "docs/NOTES.md")), turnsAfter: 160)
        let reader = try task("Review", in: repository, config: config, id: "8F7C2A51-3E0B-4C47-9C2D-6A1B0E4F9D32",
                              call: ("toolu_read", "Read", repository.appending(path: "docs/NOTES.md")))
        let elsewhere = try task("Other app", in: other, config: config, id: "8F7C2A51-3E0B-4C47-9C2D-6A1B0E4F9D33",
                                 call: ("toolu_other", "Edit", other.appending(path: "docs/NOTES.md")))
        let activity = root.appending(path: "file-activity")
        let suite = testDefaultsSuite("FileTasks")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let sessions = [editor, reader, elsewhere]
        let model = AppModel(
            store: SessionStore(sessions: sessions, repository: InMemorySessionRepository(sessions: sessions)),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            registry: HarnessRegistry { _, _ in NoClaudeRuntime() },
            modelCatalogs: HarnessModelCatalogStore(locations: HarnessModelSettingsLocations(
                claudeConfigDirectory: config, codexHome: root.appending(path: "codex-home"),
                codexYardletHome: root.appending(path: "codex-yardlet")), environment: [:]),
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults),
            preferences: defaults,
            fileTaskIndex: FileTaskIndex(repository: FileTouchRepository(directoryURL: activity)),
            transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults),
            sessionTitleResolver: { _ in nil },
            restoresIndexOnLaunch: false)
        addTeardownBlock { await model.shutdown() }

        let tasks = await model.tasks(touching: repository.appending(path: "docs/NOTES.md"))
        XCTAssertEqual(tasks.edited.map(\.title), ["Home redesign"], "the worktree's file is the repository's")
        XCTAssertEqual(tasks.edited.first?.callID, "toolu_edit")
        XCTAssertEqual(tasks.readOnly.map(\.title), ["Review"])
        let kept = try FileManager.default.contentsOfDirectory(atPath: activity.path(percentEncoded: false)).sorted()
        XCTAssertEqual(kept, ["\(editor.id.uuidString).json", "\(reader.id.uuidString).json"].sorted(),
                       "a task in another repository is not read for this file")

        // Opening the editor reads its conversation back to the call, then asks it to go there.
        await model.revealCall("toolu_edit", in: editor.id)
        XCTAssertTrue((model.transcriptBySessionID[editor.id] ?? []).contains { entry in
            if case let .activity(activity, _) = entry.content { return activity.id == "toolu_edit" }
            return false
        })
        let request = try XCTUnwrap(model.conversationPlaceRequests[editor.id])
        XCTAssertEqual(request.callID, "toolu_edit")
        XCTAssertFalse(model.isAttached(editor.id), "reading attached nothing")
        model.finishConversationPlace(request, in: editor.id)
        XCTAssertNil(model.conversationPlaceRequests[editor.id])
    }

    // MARK: - Fixtures

    /// A detached Claude task in `folder` whose transcript makes `call` in its first turn, then has
    /// `turnsAfter` turns of about 10 KB.
    private func task(_ title: String, in folder: URL, config: URL, id: String,
                      call: (id: String, tool: String, file: URL), turnsAfter: Int = 0) throws -> SessionRecord {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let projects = config.appending(path: "projects/\(ClaudeConversationCatalog.projectFolderName(for: folder))")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let at = "2026-10-26T09:00:00.000Z"
        var data = Data()
        func append(_ record: [String: JSONValue]) throws {
            data.append(try JSONEncoder().encode(JSONValue.object(record)))
            data.append(10)
        }
        try append(Self.user("Request 1", uuid: "u-1", parent: nil, session: id))
        var use = Self.call(call.id, call.tool, call.file.path(percentEncoded: false), at: at)
        use["uuid"] = .string("c-1"); use["parentUuid"] = .string("u-1"); use["sessionId"] = .string(id)
        try append(use)
        var result = Self.result(call.id, failed: false)
        result["uuid"] = .string("r-1"); result["parentUuid"] = .string("c-1"); result["sessionId"] = .string(id)
        try append(result)
        var parent = "r-1"
        try append(Self.assistant("Answer 1.", uuid: "a-1", parent: parent, session: id))
        parent = "a-1"
        for index in stride(from: 2, through: turnsAfter + 1, by: 1) where turnsAfter > 0 {
            try append(Self.user("Request \(index)", uuid: "u-\(index)", parent: parent, session: id))
            try append(Self.assistant("Answer \(index). " + String(repeating: "Words of the answer. ", count: 480),
                                      uuid: "a-\(index)", parent: "u-\(index)", session: id))
            parent = "a-\(index)"
        }
        try data.write(to: projects.appending(path: "\(id).jsonl"))
        let cli = root.appending(path: "claude")
        if !FileManager.default.fileExists(atPath: cli.path(percentEncoded: false)) {
            try Data("#!/bin/sh\n".utf8).write(to: cli)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path(percentEncoded: false))
        }
        let account = ProviderConnection(id: "claude-files", name: "files@example.test", harness: .claudeCode,
                                         providerID: nil, homePath: config.path(percentEncoded: false), credentialSelector: nil)
        return SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: cli, title: title,
                             status: .completed, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                             updatedAt: Date(timeIntervalSince1970: 1_700_000_000), providerSessionID: id,
                             connection: account)
    }

    private static func line(_ record: [String: JSONValue]) -> Data {
        var data = (try? JSONEncoder().encode(JSONValue.object(record))) ?? Data()
        data.append(10)
        return data
    }

    private static func call(_ id: String, _ tool: String, _ path: String, at: String,
                             sidechain: Bool = false) -> [String: JSONValue] {
        ["type": .string("assistant"), "timestamp": .string(at), "isSidechain": .bool(sidechain),
         "message": .object(["id": .string("m-\(id)"), "role": .string("assistant"), "content": .array([
            .object(["type": .string("tool_use"), "id": .string(id), "name": .string(tool),
                     "input": .object(["file_path": .string(path)])])])])]
    }

    private static func result(_ id: String, failed: Bool) -> [String: JSONValue] {
        var block: [String: JSONValue] = ["type": .string("tool_result"), "tool_use_id": .string(id),
                                          "content": .string(failed ? "File does not exist." : "Done.")]
        if failed { block["is_error"] = .bool(true) }
        return ["type": .string("user"), "isSidechain": .bool(false),
                "message": .object(["role": .string("user"), "content": .array([.object(block)])])]
    }

    private static func user(_ text: String, uuid: String, parent: String?, session: String) -> [String: JSONValue] {
        ["type": .string("user"), "uuid": .string(uuid), "parentUuid": parent.map(JSONValue.string) ?? .null,
         "sessionId": .string(session), "isSidechain": .bool(false),
         "message": .object(["role": .string("user"), "content": .string(text)])]
    }

    private static func assistant(_ text: String, uuid: String, parent: String, session: String) -> [String: JSONValue] {
        ["type": .string("assistant"), "uuid": .string(uuid), "parentUuid": .string(parent), "sessionId": .string(session),
         "message": .object(["id": .string("m-\(uuid)"), "role": .string("assistant"),
                             "content": .array([.object(["type": .string("text"), "text": .string(text)])])])]
    }
}

/// A Claude runtime the test never starts: reading a task's conversation needs none.
private actor NoClaudeRuntime: HarnessAdapter {
    nonisolated let kind = HarnessKind.claudeCode

    func probeRuntime() async throws -> HarnessRuntimeDescriptor {
        HarnessRuntimeDescriptor(harness: kind, executableURL: URL(filePath: "/tmp/stub"), version: "stub",
                                 capabilities: .unavailable, fingerprint: "stub")
    }
    func createSession(_ request: CreateHarnessSessionRequest) async throws -> HarnessSessionHandle {
        XCTFail("no session is created")
        throw CancellationError()
    }
    func resumeSession(providerSessionID: String, localSessionID: UUID, workspaceURL: URL) async throws -> HarnessSessionHandle {
        XCTFail("no session is resumed")
        throw CancellationError()
    }
    func send(_ prompt: String, to session: HarnessSessionHandle) async throws {}
    func interrupt(_ session: HarnessSessionHandle) async throws {}
    func respond(to permissionRequestID: String, decision: PermissionDecision, in session: HarnessSessionHandle) async throws {}
    func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> { AsyncStream { _ in } }
    func close(_ session: HarnessSessionHandle) async {}
}
