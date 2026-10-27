import Foundation
import Observation
import XCTest
@testable import NativeHarnessClient

/// What many concurrently streaming tasks must not change: every fragment arrives in order,
/// a background task's output leaves the shown task's view alone, approvals in a background
/// task surface at once, and snapshots of streaming state are kept without one write per
/// fragment or one stored copy per timeline state.
@MainActor
final class StreamingPublicationTests: XCTestCase {
    // MARK: Per-task observation

    func testReadingOneTaskIsNotInvalidatedByAnotherTasksValue() {
        let table = TaskStateTable<[Int]>()
        let shown = UUID(), background = UUID()
        table[shown] = [1]
        let invalidated = Flag()
        withObservationTracking { _ = table[shown] } onChange: { invalidated.set() }
        table[background] = [2]
        table[background] = [2, 3]
        table.removeValue(forKey: background)
        XCTAssertFalse(invalidated.value)
        table[shown] = [1, 2]
        XCTAssertTrue(invalidated.value)
    }

    func testATaskReadBeforeItHasAValueIsInvalidatedWhenItGetsOne() {
        let table = TaskStateTable<String>()
        let id = UUID()
        let invalidated = Flag()
        withObservationTracking { XCTAssertNil(table[id]) } onChange: { invalidated.set() }
        table[id] = "first"
        XCTAssertTrue(invalidated.value)
        XCTAssertEqual(table[id], "first")
    }

    func testReadingTheWholeTableSeesTasksArriveChangeAndLeave() {
        let table = TaskStateTable<Int>([UUID(): 1])
        let added = UUID()
        let changes: [() -> Void] = [{ table[added] = 2 }, { table[added] = 3 }, { _ = table.removeValue(forKey: added) }]
        for change in changes {
            let invalidated = Flag()
            withObservationTracking { _ = table.dictionary } onChange: { invalidated.set() }
            change()
            XCTAssertTrue(invalidated.value)
        }
        XCTAssertEqual(table.dictionary.count, 1)
        XCTAssertFalse(table.isEmpty)
        table.removeAll()
        XCTAssertTrue(table.isEmpty)
    }

    // MARK: App model through the product Claude route

    func testBackgroundThinkingAndAnswerFragmentsArriveInOrderWithoutInvalidatingTheShownTask() async throws {
        let fixture = try await TwoClaudeTasks.make(testCase: self)
        let model = fixture.model
        let shownChanged = Flag()
        withObservationTracking {
            _ = model.transcriptBySessionID[fixture.shown.id]
            _ = model.codexPresentationBySessionID[fixture.shown.id]
        } onChange: { shownChanged.set() }
        // The sidebar reads every task's attention detail; streaming text does not change it.
        let detailsChanged = Flag()
        withObservationTracking { _ = model.taskAttentionDetails } onChange: { detailsChanged.set() }

        for (kind, text) in [("thinking", "Read "), ("thinking", "the file."), ("text", "It "), ("text", "works."),
                             ("thinking", "Check "), ("thinking", "tests."), ("text", " Done.")] {
            await fixture.backgroundTransport.emit(.object([
                "type": .string("stream_event"),
                "event": .object(["type": .string("content_block_delta"), "delta": .object(
                    kind == "thinking"
                        ? ["type": .string("thinking_delta"), "thinking": .string(text)]
                        : ["type": .string("text_delta"), "text": .string(text)]
                )])
            ]))
        }
        let expected = ["user: Background work", "reasoning: Read the file.", "assistant: It works.",
                        "reasoning: Check tests.", "assistant:  Done."]
        try await waitUntil { fixture.lines(fixture.background) == expected }
        XCTAssertEqual(fixture.lines(fixture.background), expected)
        XCTAssertFalse(shownChanged.value, "Another task's stream must not invalidate the shown task")
        XCTAssertFalse(detailsChanged.value, "Streamed text must not redraw the sidebar's task states")
    }

    func testABackgroundApprovalSurfacesAtOnceWithUnreadAndANotification() async throws {
        let fixture = try await TwoClaudeTasks.make(testCase: self)
        let model = fixture.model
        await fixture.backgroundTransport.emit(.object([
            "type": .string("control_request"),
            "request_id": .string("permission-1"),
            "request": .object([
                "subtype": .string("can_use_tool"),
                "tool_name": .string("Bash"),
                "input": .object(["command": .string("git status")]),
                "title": .string("Run command")
            ])
        ]))
        try await waitUntil {
            model.store.sessions.first { $0.id == fixture.background.id }?.status == .waitingForApproval
        }
        let task = try XCTUnwrap(model.store.sessions.first { $0.id == fixture.background.id })
        XCTAssertTrue(task.hasUnreadUpdate)
        XCTAssertTrue(fixture.lines(fixture.background).contains("permission: permission-1 pending"),
                      "The approval card is published with the status, not after a coalescing window")
        XCTAssertEqual(model.taskAttentionDetails[task.id]?.pendingRequest, .approval)
        XCTAssertEqual(SidebarTaskIndicatorProjection.status(of: task, detail: model.taskAttentionDetails[task.id]),
                       .awaitingApproval, "The sidebar shows it waiting, not running")
        XCTAssertEqual(TaskAttentionProjection.nextSession(in: model.store.sessions, excluding: fixture.shown.id,
                                                           details: model.taskAttentionDetails), task.id)
        try await waitUntil { fixture.notifications.posts == 1 }
    }

    // MARK: Snapshots

    func testStreamedTranscriptSnapshotsAreWrittenOncePerBurstAndFlushedOnDemand() async throws {
        let repository = RecordingTranscriptRepository()
        let writer = TranscriptSnapshotWriter(repository: repository, delay: .milliseconds(100))
        let id = UUID()
        for count in 1...50 {
            writer.scheduleSave((0..<count).map { TranscriptEntry(content: .assistant(text: "\($0)", isStreaming: true)) }, for: id)
        }
        XCTAssertEqual(repository.saves, 0, "Nothing is written while the burst continues")
        try await Task.sleep(for: .milliseconds(300))
        writer.flush()
        XCTAssertEqual(repository.saves, 1)
        XCTAssertEqual(repository.load(for: id).count, 50, "The newest snapshot of the burst is the one written")

        writer.scheduleSave([TranscriptEntry(content: .user(text: "Latest"))], for: id)
        writer.flush()
        XCTAssertEqual(repository.load(for: id).map(\.content), [.user(text: "Latest")], "Shutdown writes what is waiting")

        writer.scheduleSave([TranscriptEntry(content: .user(text: "Deleted"))], for: id)
        writer.remove(for: id)
        try await Task.sleep(for: .milliseconds(300))
        writer.flush()
        XCTAssertTrue(repository.load(for: id).isEmpty, "A removed task's waiting snapshot is not written afterwards")
    }

    func testProtocolHistoryKeepsTheNewestCodexSnapshotAndTheNewestEvents() {
        let id = UUID()
        var sequence: UInt64 = 0
        func event(_ payload: HarnessProtocolEventPayload) -> HarnessProtocolEventEnvelope {
            defer { sequence += 1 }
            return HarnessProtocolEventEnvelope(localSessionID: id, sequence: sequence, payload: payload)
        }
        func snapshot(_ turns: Int) -> HarnessProtocolEventEnvelope {
            event(.extensionEvent(HarnessProtocolExtensionEvent(
                namespace: "yardlet.codex", name: "presentation.updated", payload: .object(["turns": .integer(Int64(turns))])
            )))
        }
        var history = HarnessProtocolEventHistory(limit: 500)
        history.append(snapshot(1))
        history.append(event(.assistantDelta(turnID: "t", messageID: "m", text: "a")))
        history.append(snapshot(2))
        history.append(event(.assistantDelta(turnID: "t", messageID: "m", text: "b")))
        history.append(snapshot(3))
        XCTAssertEqual(history.events.map(\.sequence), [0, 1, 2, 3, 4], "A late subscriber still sees every sequence")
        XCTAssertEqual(history.events.map { $0.payload.extensionEvent?.name }, [
            "presentation.superseded", nil, "presentation.superseded", nil, "presentation.updated"
        ], "Only the newest snapshot keeps its timeline")
        XCTAssertEqual(history.events.last?.payload.extensionEvent?.payload, .object(["turns": .integer(3)]))
        XCTAssertEqual(history.events.first?.payload.extensionEvent?.payload, .null)

        for _ in 0..<600 { history.append(event(.assistantDelta(turnID: "t", messageID: "m", text: "x"))) }
        XCTAssertEqual(history.events.count, 500)
        XCTAssertEqual(history.events.last?.sequence, sequence - 1)
        history.append(snapshot(4))
        XCTAssertEqual(history.events.filter(\.isCodexPresentationSnapshot).count, 1)
    }

    func testJSONValuesDecodeToTheSameKindsWhateverOrderTheyAreTried() throws {
        let data = Data(#"""
        {"s":"1","t":true,"f":false,"i":42,"neg":-7,"big":9007199254740993,"d":1.5,
         "n":null,"o":{"nested":["x",1,false,null,{"k":"v"}]},"a":[],"empty":{},"num":"true"}
        """#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(value, .object([
            "s": .string("1"), "t": .bool(true), "f": .bool(false), "i": .integer(42), "neg": .integer(-7),
            "big": .integer(9_007_199_254_740_993), "d": .number(1.5), "n": .null,
            "o": .object(["nested": .array([.string("x"), .integer(1), .bool(false), .null, .object(["k": .string("v")])])]),
            "a": .array([]), "empty": .object([:]), "num": .string("true")
        ]))
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)), value)
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        let satisfied = await condition()
        XCTAssertTrue(satisfied, "Timed out")
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false
    func set() { lock.withLock { isSet = true } }
    var value: Bool { lock.withLock { isSet } }
}

private final class RecordingTranscriptRepository: TranscriptRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UUID: [TranscriptEntry]] = [:]
    private var saveCount = 0
    var saves: Int { lock.withLock { saveCount } }
    func load(for sessionID: UUID) -> [TranscriptEntry] { lock.withLock { stored[sessionID] ?? [] } }
    func save(_ entries: [TranscriptEntry], for sessionID: UUID) {
        lock.withLock {
            saveCount += 1
            stored[sessionID] = entries
        }
    }
    func remove(for sessionID: UUID) { lock.withLock { _ = stored.removeValue(forKey: sessionID) } }
}

private final class PostCountingNotificationCenter: SystemNotificationCenter {
    private(set) var posts = 0
    func authorization() async -> SystemNotificationAuthorization { .authorized }
    func requestAuthorization() async -> Bool { true }
    func post(title: String, body: String, identifier: String) async { posts += 1 }
}

private final class TransportsByTask: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [UUID: FakeClaudeTransport] = [:]
    func make(for id: UUID) -> FakeClaudeTransport {
        let transport = FakeClaudeTransport()
        lock.withLock { transports[id] = transport }
        return transport
    }
    func transport(for id: UUID) -> FakeClaudeTransport? { lock.withLock { transports[id] } }
}

/// Two Claude tasks on the product route: one shown, one running in the background.
@MainActor
private struct TwoClaudeTasks {
    let model: AppModel
    let shown: SessionRecord
    let background: SessionRecord
    let backgroundTransport: FakeClaudeTransport
    let notifications: PostCountingNotificationCenter

    static func make(testCase: XCTestCase) async throws -> TwoClaudeTasks {
        let root = FileManager.default.temporaryDirectory.appending(path: "streaming-publication-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let cli = root.appending(path: "claude")
        try Data("""
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo '2.1.291 (Claude Code)'; exit 0; fi

        """.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let suite = testDefaultsSuite("StreamingPublication")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let transports = TransportsByTask()
        let notifications = PostCountingNotificationCenter()
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            registry: HarnessRegistry { _, url in
                YHPProviderCompatibilityAdapter(
                    adapter: ClaudeAdapter(executableURL: url, transportFactory: { transports.make(for: $0) }),
                    manifest: HarnessProtocolCompatibilityManifest.claude()
                )
            },
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults),
            preferences: defaults,
            transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults),
            sessionTitleResolver: { _ in nil },
            sessionTitleRetryCount: 0,
            systemNotificationCenter: notifications,
            restoresIndexOnLaunch: false
        )
        testCase.addTeardownBlock { await model.shutdown() }
        var tasks: [SessionRecord] = []
        for name in ["Shown", "Background"] {
            let folder = root.appending(path: name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let created = await model.createSession(harness: .claudeCode, workspaceURL: folder,
                                                    runtimeExecutableURL: cli, title: name)
            tasks.append(try XCTUnwrap(created, model.errorBySessionID.values.first ?? "\(name) did not start"))
        }
        model.store.selectedSessionID = tasks[0].id
        await model.send(HarnessUserInput(text: "Background work"), to: tasks[1])
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline,
              model.store.sessions.first(where: { $0.id == tasks[1].id })?.status != .running {
            try await Task.sleep(for: .milliseconds(10))
        }
        return TwoClaudeTasks(
            model: model, shown: tasks[0], background: tasks[1],
            backgroundTransport: try XCTUnwrap(transports.transport(for: tasks[1].id)),
            notifications: notifications
        )
    }

    func lines(_ task: SessionRecord) -> [String] {
        (model.transcriptBySessionID[task.id] ?? []).compactMap { entry in
            switch entry.content {
            case let .user(text, _): "user: \(text)"
            case let .assistant(text, _): "assistant: \(text)"
            case let .reasoning(text, _): "reasoning: \(text)"
            case let .permission(request, state): "permission: \(request.id) \(state)"
            default: nil
            }
        }
    }
}
