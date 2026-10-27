import XCTest
@testable import NativeHarnessClient

/// A task's recency (`updatedAt`, which orders the sidebar) moves only with activity: a message
/// sent, a turn running or ending, a rename. Connecting a saved task's runtime, as opening its
/// model menu does, the ready state the runtime reports then, and a setting chosen for the task
/// leave it where it was. The installed app moved an idle Claude task to the top of the sidebar
/// when its model menu was opened.
@MainActor
final class TaskRecencyTests: XCTestCase {
    func testConnectingAClaudeTaskLeavesItsPlaceInTheSidebar() async throws {
        let fixture = try await ClaudeFixture.make(settings: "{}", in: self)
        let model = fixture.model, idle = fixture.session
        let newer = try await newerTask(beside: idle, in: model)
        let before = try current(model, idle).updatedAt
        XCTAssertEqual(sidebar(model), [newer.id, idle.id])

        // What opening the model menu does when it has no list to show: it connects to read one.
        await model.loadProviderCapabilities(for: try current(model, idle))
        XCTAssertTrue(model.isAttached(idle.id))
        try await waitForEvents(of: idle, in: model) { $0.contains { $0.payload == .sessionStatusChanged(.ready) } }
        XCTAssertEqual(try current(model, idle).updatedAt, before, "Connecting is not activity")
        XCTAssertEqual(sidebar(model), [newer.id, idle.id])

        await model.setProviderOption("effort", value: "low", for: try current(model, idle))
        XCTAssertEqual(try current(model, idle).providerOptions["effort"], "low")
        XCTAssertEqual(try current(model, idle).updatedAt, before, "A setting is not activity")
        XCTAssertEqual(sidebar(model), [newer.id, idle.id])

        // A message sent is.
        await model.send(HarnessUserInput(text: "Run the tests"), to: try current(model, idle))
        XCTAssertGreaterThan(try current(model, idle).updatedAt, before)
        XCTAssertEqual(sidebar(model), [idle.id, newer.id])
    }

    func testConnectingACodexTaskLeavesItsPlaceInTheSidebar() async throws {
        let fixture = try CodexFixture(config: "model = \"gpt-test\"\n", in: self)
        let model = fixture.model, idle = fixture.session
        let newer = try await newerTask(beside: idle, in: model)
        let before = try current(model, idle).updatedAt
        XCTAssertEqual(sidebar(model), [newer.id, idle.id])

        await model.loadCodexModels(for: try current(model, idle))
        XCTAssertTrue(model.isAttached(idle.id))
        let resumed = await fixture.transport.requestMethods
        XCTAssertTrue(resumed.contains("thread/resume"))
        try await waitForEvents(of: idle, in: model) { $0.contains { $0.payload == .sessionStatusChanged(.ready) } }
        XCTAssertEqual(try current(model, idle).updatedAt, before, "Connecting is not activity")
        XCTAssertEqual(sidebar(model), [newer.id, idle.id])

        await model.selectCodexModel(CodexModelSelection(model: "gpt-test", reasoningEffort: "low"),
                                     for: try current(model, idle))
        XCTAssertEqual(try current(model, idle).updatedAt, before, "A setting is not activity")
        XCTAssertEqual(sidebar(model), [newer.id, idle.id])

        await model.submitCodex(CodexComposerDraft(inputs: [.text("Run the tests")]), action: .automatic,
                                to: try current(model, idle))
        XCTAssertGreaterThan(try current(model, idle).updatedAt, before)
        XCTAssertEqual(sidebar(model), [idle.id, newer.id])
    }

    /// The store's own rule, as the attach path and the runtime's reports use it.
    func testTheStoreMovesATaskOnlyForActivity() async throws {
        let saved = Date(timeIntervalSince1970: 1_700_000_000)
        let session = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/recency"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Saved", status: .completed,
            createdAt: saved, updatedAt: saved, providerSessionID: "saved")
        let repository = InMemorySessionRepository(sessions: [session])
        let store = SessionStore(sessions: [session], repository: repository)

        try await store.updateSession(id: session.id, status: .ready, providerSessionID: "saved",
                                      setProviderSessionID: true, updatesRecency: false)
        try await store.updateProviderOption(id: session.id, optionID: "model", value: "sonnet")
        XCTAssertEqual(store.sessions.first?.updatedAt, saved)
        XCTAssertEqual(store.sessions.first?.status, SessionStatus.ready)
        XCTAssertEqual(store.sessions.first?.providerOptions, ["model": "sonnet"])
        let persisted = try await repository.loadSessions()
        XCTAssertEqual(persisted.first?.updatedAt, saved)

        try await store.updateSession(id: session.id, status: .running)
        XCTAssertGreaterThan(try XCTUnwrap(store.sessions.first?.updatedAt), saved)
    }

    // MARK: - Helpers

    /// A task in the same project made after `session`, so it sits above it in the sidebar.
    private func newerTask(beside session: SessionRecord, in model: AppModel) async throws -> SessionRecord {
        try await Task.sleep(for: .milliseconds(20))
        return try await model.store.createSession(
            harness: session.harness, workspaceURL: session.workspaceURL,
            runtimeExecutableURL: session.runtimeExecutableURL, title: "Newer", selectsSession: false)
    }

    private func sidebar(_ model: AppModel) -> [UUID] {
        TaskNavigationProjection.flattenedSessionIDs(in: model.store.workspaceGroups)
    }

    private func current(_ model: AppModel, _ session: SessionRecord) throws -> SessionRecord {
        try XCTUnwrap(model.store.sessions.first { $0.id == session.id })
    }

    /// Waits until the runtime's events for `session` that `condition` looks for have been taken
    /// in, so what they change in the store is there to check.
    private func waitForEvents(of session: SessionRecord, in model: AppModel,
                               until condition: ([HarnessEventEnvelope]) -> Bool) async throws {
        for _ in 0..<200 {
            if condition(model.eventsBySessionID[session.id] ?? []) {
                // Taking an event in finishes with its store write; let that write land.
                try await Task.sleep(for: .milliseconds(50))
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The runtime's events did not arrive")
    }
}
