import XCTest
@testable import NativeHarnessClient

/// The collaboration mode a person chose stays the task's mode: a model, effort or Fast change
/// keeps it, the task keeps it across a restart and a fork, and only an explicit Plan toggle or
/// "implement this plan" returns it to Default.
@MainActor
final class CodexModePreservationTests: XCTestCase {
    func testChangingEffortOrFastKeepsPlanModeAndTheNextTurnCarriesAllThree() async throws {
        for routed in [false, true] {
            let fixture = try CommandFixture(routed: routed)
            defer { fixture.cleanup() }
            let model = fixture.model, session = fixture.session
            await model.prepareCodexComposerCommands(for: session)
            await model.runCodexComposerCommand(.planMode, in: try current(model, session))
            XCTAssertEqual(selectedMode(model, session), "plan")

            await model.selectCodexModel(.init(model: "gpt-test", reasoningEffort: "low"), for: try current(model, session))
            XCTAssertEqual(selectedMode(model, session), "plan", "An effort change keeps Plan (routed: \(routed))")
            await model.runCodexComposerCommand(.serviceTier("priority"), in: try current(model, session))
            XCTAssertEqual(selectedMode(model, session), "plan", "Fast keeps Plan (routed: \(routed))")
            XCTAssertEqual(composerMode(model, session), "plan", "routed: \(routed)")

            await model.submitCodex(.init(inputs: [.text("Plan the change")]), action: .automatic, to: try current(model, session))
            let start = try await lastTurnStart(fixture.transport)
            XCTAssertEqual(start.params["model"], .string("gpt-test"))
            XCTAssertEqual(start.params["effort"], .string("low"))
            XCTAssertEqual(start.params["serviceTier"], .string("priority"))
            XCTAssertEqual(start.params["collaborationMode"], .object([
                "mode": .string("plan"),
                "settings": .object(["model": .string("gpt-test"), "reasoning_effort": .string("low")])
            ]), "routed: \(routed)")
            await model.shutdown()
        }
    }

    func testTheChosenModeIsKeptWithTheTaskAndRestoredAfterARestart() async throws {
        var saved: [String: String] = [:]
        do {
            let fixture = try CommandFixture(routed: false)
            defer { fixture.cleanup() }
            let model = fixture.model, session = fixture.session
            await model.prepareCodexComposerCommands(for: session)
            await model.runCodexComposerCommand(.planMode, in: try current(model, session))
            saved = try current(model, session).providerOptions
            XCTAssertEqual(CodexCollaborationPreset.restored(from: saved)?.mode, "plan")
            await model.shutdown()
        }
        for routed in [false, true] {
            let fixture = try CommandFixture(routed: routed, providerOptions: saved)
            defer { fixture.cleanup() }
            let model = fixture.model, session = fixture.session
            // Before the runtime lists its presets, the composer already shows the task's mode.
            XCTAssertEqual(composerMode(model, session), "plan", "routed: \(routed)")
            await model.prepareCodexComposerCommands(for: session)
            XCTAssertEqual(selectedMode(model, session), "plan", "routed: \(routed)")
            XCTAssertEqual(composerMode(model, session), "plan", "routed: \(routed)")
            await model.submitCodex(.init(inputs: [.text("Continue planning")]), action: .automatic, to: try current(model, session))
            let start = try await lastTurnStart(fixture.transport)
            XCTAssertEqual(start.params["collaborationMode"]?["mode"], .string("plan"), "routed: \(routed)")
            XCTAssertEqual(start.params["collaborationMode"]?["settings"]?["model"], .string("gpt-test"))
            XCTAssertEqual(try current(model, session).providerSessionID, "original")
            XCTAssertEqual(try current(model, session).environmentScope, .yardlet)
            await model.shutdown()
        }
    }

    /// Right after a restart the composer shows the saved Plan before the runtime lists its
    /// presets; clicking that Plan chip leaves Plan without a prior listing, and the record, the
    /// composer and the next turn all say Default. The draft stays as it was.
    func testLeavingARestoredPlanBeforeTheModesAreListedReturnsToDefault() async throws {
        let plan = CodexCollaborationPreset(name: "Plan", mode: "plan", model: "gpt-test", reasoningEffort: "high")
        for routed in [false, true] {
            let fixture = try CommandFixture(routed: routed,
                providerOptions: [CodexCollaborationPreset.storageKey: try XCTUnwrap(plan.storedValue)])
            defer { fixture.cleanup() }
            let model = fixture.model, session = fixture.session
            model.composerDrafts.tasks.draft(for: session.id).text = "Half-written follow-up"
            XCTAssertEqual(composerMode(model, session), "plan", "routed: \(routed)")
            XCTAssertNil(model.codexCapabilitiesBySessionID[session.id], "routed: \(routed)")

            await model.runCodexComposerCommand(.planMode, in: try current(model, session))
            XCTAssertEqual(selectedMode(model, session), "default", "routed: \(routed)")
            XCTAssertEqual(composerMode(model, session), "default", "routed: \(routed)")
            XCTAssertEqual(CodexCollaborationPreset.restored(from: try current(model, session).providerOptions)?.mode,
                           "default", "routed: \(routed)")
            XCTAssertNil(model.composerDrafts.tasks.draft(for: session.id).notice, "routed: \(routed)")
            XCTAssertEqual(model.composerDrafts.tasks.draft(for: session.id).text, "Half-written follow-up")
            XCTAssertEqual(try current(model, session).providerSessionID, "original")

            await model.submitCodex(.init(inputs: [.text("Build it")]), action: .automatic, to: try current(model, session))
            let start = try await lastTurnStart(fixture.transport)
            XCTAssertEqual(start.params["collaborationMode"]?["mode"], .string("default"), "routed: \(routed)")
            await model.shutdown()
        }
    }

    func testARecordWithoutAModeKeepsTheHarnessDefault() async throws {
        let fixture = try CommandFixture(routed: false, providerOptions: [
            CodexModelSelection.storageKey: try XCTUnwrap(CodexModelSelection(model: "gpt-test", reasoningEffort: "low").storedValue)
        ])
        defer { fixture.cleanup() }
        let model = fixture.model, session = fixture.session
        await model.prepareCodexComposerCommands(for: session)
        XCTAssertNil(model.codexCapabilitiesBySessionID[session.id]?.selectedModeID)
        XCTAssertNil(model.composerCodexCapabilities(for: try current(model, session)).selectedModeID)
        await model.submitCodex(.init(inputs: [.text("Hello")]), action: .automatic, to: try current(model, session))
        let start = try await lastTurnStart(fixture.transport)
        XCTAssertNil(start.params["collaborationMode"])
        XCTAssertEqual(start.params["effort"], .string("low"))
        await model.shutdown()
    }

    func testLeavingPlanAndImplementingAPlanAreKeptAsDefault() async throws {
        let fixture = try CommandFixture(routed: false)
        defer { fixture.cleanup() }
        let model = fixture.model, session = fixture.session
        await model.prepareCodexComposerCommands(for: session)
        await model.runCodexComposerCommand(.planMode, in: try current(model, session))
        await model.runCodexComposerCommand(.planMode, in: try current(model, session))
        XCTAssertEqual(selectedMode(model, session), "default")
        XCTAssertEqual(CodexCollaborationPreset.restored(from: try current(model, session).providerOptions)?.mode, "default")

        await model.runCodexComposerCommand(.planMode, in: try current(model, session))
        XCTAssertEqual(CodexCollaborationPreset.restored(from: try current(model, session).providerOptions)?.mode, "plan")
        await model.implementCodexPlan("1. Do it", in: try current(model, session))
        XCTAssertEqual(selectedMode(model, session), "default")
        XCTAssertEqual(CodexCollaborationPreset.restored(from: try current(model, session).providerOptions)?.mode, "default")
        let start = try await lastTurnStart(fixture.transport)
        XCTAssertEqual(start.params["collaborationMode"]?["mode"], .string("default"))
        await model.shutdown()
    }

    func testAFailedModelOrModeChangeKeepsTheModeTheTaskRecords() async throws {
        let modes = JSONValue.object(["data": .array([
            .object(["name": .string("Plan"), "mode": .string("plan"), "model": .string("gpt-test")]),
            .object(["name": .string("Default"), "mode": .string("default"), "model": .string("gpt-test")]),
            .object(["name": .string("Pair"), "mode": .string("pair"), "model": .string("gpt-test")])])])
        for routed in [false, true] {
            let fixture = try CommandFixture(routed: routed, collaborationModes: modes)
            defer { fixture.cleanup() }
            let model = fixture.model, session = fixture.session
            await model.prepareCodexComposerCommands(for: session)
            await model.runCodexComposerCommand(.planMode, in: try current(model, session))
            let saved = try current(model, session).providerOptions

            await model.selectCodexModel(.init(model: "gpt-test", reasoningEffort: "xhigh"), for: try current(model, session))
            XCTAssertEqual(selectedMode(model, session), "plan", "routed: \(routed)")
            let pair = try XCTUnwrap(model.codexCapabilitiesBySessionID[session.id]?.modes.first { $0.mode == "pair" })
            await model.selectCodexMode(pair.id, for: try current(model, session))
            XCTAssertEqual(selectedMode(model, session), "plan", "routed: \(routed)")
            XCTAssertEqual(try current(model, session).providerOptions, saved, "routed: \(routed)")

            await model.submitCodex(.init(inputs: [.text("Still planning")]), action: .automatic, to: try current(model, session))
            let start = try await lastTurnStart(fixture.transport)
            XCTAssertEqual(start.params["collaborationMode"]?["mode"], .string("plan"), "routed: \(routed)")
            XCTAssertEqual(start.params["effort"], .string("high"), "routed: \(routed)")
            await model.shutdown()
        }
    }

    func testAForkKeepsTheSourcesModeAndANewChatKeepsTheSourcesOptionsAsBefore() async throws {
        let fixture = try CommandFixture(routed: false)
        defer { fixture.cleanup() }
        let model = fixture.model, session = fixture.session
        await model.prepareCodexComposerCommands(for: session)
        await model.runCodexComposerCommand(.planMode, in: try current(model, session))
        await model.runCodexComposerCommand(.fork, in: try current(model, session))
        let fork = try XCTUnwrap(model.store.sessions.first { $0.providerSessionID == "child" })
        XCTAssertEqual(CodexCollaborationPreset.restored(from: fork.providerOptions)?.mode, "plan")
        XCTAssertEqual(selectedMode(model, fork), "plan")
        XCTAssertEqual(composerMode(model, fork), "plan")
        await model.submitCodex(.init(inputs: [.text("Plan in the fork")]), action: .automatic, to: fork)
        let start = try await lastTurnStart(fixture.transport)
        XCTAssertEqual(start.params["threadId"], .string("child"))
        XCTAssertEqual(start.params["collaborationMode"]?["mode"], .string("plan"))

        let before = Set(model.store.sessions.map(\.id))
        await model.runCodexComposerCommand(.newChat, in: try current(model, session))
        // A new chat copies the source's options whole, as it did before modes were kept; its
        // composer shows the same mode its launch options hand the adapter.
        let fresh = try XCTUnwrap(model.store.sessions.first { !before.contains($0.id) })
        XCTAssertEqual(fresh.providerOptions, try current(model, session).providerOptions)
        XCTAssertEqual(composerMode(model, fresh), "plan")
        await model.shutdown()
    }

    /// A runtime that renames its presets: the choice the app held is no longer listed, so the
    /// task's saved mode picks the new preset with the same mode, the turn still runs in Plan,
    /// and leaving Plan resolves against the new list on both routes.
    func testARenamedPresetStillShowsAndSendsTheSavedMode() async throws {
        func listing(_ planName: String) -> JSONValue {
            .object(["data": .array([
                .object(["name": .string(planName), "mode": .string("plan"), "model": .string("gpt-test")]),
                .object(["name": .string("Default"), "mode": .string("default"), "model": .string("gpt-test")])])])
        }
        let old = listing("Planning"), renamed = listing("Plan")
        for routed in [false, true] {
            // The YHP route lists again to resolve each selection, so its old list lasts one read longer.
            let fixture = try CommandFixture(routed: routed, collaborationModeListings: routed
                ? [old, old, renamed, renamed, renamed] : [old, renamed, renamed])
            defer { fixture.cleanup() }
            let model = fixture.model, session = fixture.session
            await model.prepareCodexComposerCommands(for: session)
            await model.runCodexComposerCommand(.planMode, in: try current(model, session))
            let chosen = model.codexCapabilitiesBySessionID[session.id]?.selectedModeID
            XCTAssertEqual(chosen?.hasPrefix("Planning|"), true, "routed: \(routed)")

            await model.loadCodexCapabilities(for: try current(model, session))
            let state = try XCTUnwrap(model.codexCapabilitiesBySessionID[session.id])
            XCTAssertFalse(state.modes.contains { $0.id == chosen }, "routed: \(routed)")
            XCTAssertEqual(state.modes.first { $0.id == state.selectedModeID }?.name, "Plan", "routed: \(routed)")
            XCTAssertEqual(composerMode(model, session), "plan", "routed: \(routed)")
            XCTAssertEqual(CodexCollaborationPreset.restored(from: try current(model, session).providerOptions)?.mode, "plan")

            await model.submitCodex(.init(inputs: [.text("Keep planning")]), action: .automatic, to: try current(model, session))
            let start = try await lastTurnStart(fixture.transport)
            XCTAssertEqual(start.params["collaborationMode"]?["mode"], .string("plan"), "routed: \(routed)")

            await model.runCodexComposerCommand(.planMode, in: try current(model, session))
            XCTAssertEqual(selectedMode(model, session), "default", "routed: \(routed)")
            XCTAssertEqual(CodexCollaborationPreset.restored(from: try current(model, session).providerOptions)?.mode,
                           "default", "routed: \(routed)")
            await model.shutdown()
        }
    }

    /// A save that fails after the runtime renamed its presets: the provider is put back in the
    /// task's recorded Plan through the runtime's current list (YHP rejects the old preset's ID),
    /// so the saved mode, the composer and the next turn still agree.
    func testAFailedSaveAfterARenameKeepsTheRecordedModeInTheProvider() async throws {
        func listing(_ planName: String) -> JSONValue {
            .object(["data": .array([
                .object(["name": .string(planName), "mode": .string("plan"), "model": .string("gpt-test")]),
                .object(["name": .string("Default"), "mode": .string("default"), "model": .string("gpt-test")])])])
        }
        let old = listing("Planning"), renamed = listing("Plan")
        for routed in [false, true] {
            let saves = ModeSaveGate()
            let fixture = try CommandFixture(routed: routed,
                collaborationModeListings: (routed ? [old, old] : [old]) + Array(repeating: renamed, count: 8),
                repository: { ModeSaveFailingRepository(sessions: $0, gate: saves) })
            defer { fixture.cleanup() }
            let model = fixture.model, session = fixture.session
            await model.prepareCodexComposerCommands(for: session)
            await model.runCodexComposerCommand(.planMode, in: try current(model, session))
            let saved = try current(model, session).providerOptions
            XCTAssertEqual(CodexCollaborationPreset.restored(from: saved)?.name, "Planning", "routed: \(routed)")

            // The runtime now lists "Plan"; the composer still holds the "Planning" it listed before.
            await saves.setFailing(true)
            await model.runCodexComposerCommand(.planMode, in: try current(model, session))
            XCTAssertEqual(try current(model, session).providerOptions, saved, "routed: \(routed)")
            XCTAssertEqual(selectedMode(model, session), "plan", "routed: \(routed)")
            XCTAssertEqual(composerMode(model, session), "plan", "routed: \(routed)")
            XCTAssertNotNil(model.composerDrafts.tasks.draft(for: session.id).notice, "routed: \(routed)")

            await model.submitCodex(.init(inputs: [.text("Still planning")]), action: .automatic, to: try current(model, session))
            let start = try await lastTurnStart(fixture.transport)
            XCTAssertEqual(start.params["collaborationMode"]?["mode"], .string("plan"), "routed: \(routed)")

            await saves.setFailing(false)
            await model.runCodexComposerCommand(.planMode, in: try current(model, session))
            XCTAssertEqual(selectedMode(model, session), "default", "routed: \(routed)")
            XCTAssertEqual(CodexCollaborationPreset.restored(from: try current(model, session).providerOptions)?.mode,
                           "default", "routed: \(routed)")
            await model.shutdown()
        }
    }

    /// The adapter alone: a saved mode handed over before resume reaches the first turn, and a
    /// model change after it leaves it in place.
    func testTheAdapterSendsARestoredModeAndKeepsItAcrossAModelChange() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/resume": [.object(["thread": .object(["id": .string("thread"), "turns": .array([])]),
                "model": .string("gpt-test"), "reasoningEffort": .string("low")])],
            "thread/turns/list": [.object(["data": .array([]), "nextCursor": .null])],
            "thread/items/list": [.object(["data": .array([]), "nextCursor": .null])],
            "model/list": [.object(["data": .array([.object([
                "id": .string("gpt-test"), "model": .string("gpt-test"), "displayName": .string("GPT Test"),
                "defaultReasoningEffort": .string("low"), "supportedReasoningEfforts": .array([
                    .object(["reasoningEffort": .string("low")]), .object(["reasoningEffort": .string("high")])])])])])],
            "turn/start": [.object(["turn": .object(["id": .string("turn-1")])]),
                           .object(["turn": .object(["id": .string("turn-2")])])]
        ])
        let adapter = CodexAdapter(executableURL: URL(filePath: "/tmp/fixture-codex"), transport: transport)
        let localID = UUID()
        let plan = CodexCollaborationPreset(name: "Plan", mode: "plan", model: nil, reasoningEffort: nil)
        await adapter.setLaunchOptions([CodexCollaborationPreset.storageKey: try XCTUnwrap(plan.storedValue)], for: localID)
        let handle = try await adapter.resumeSession(providerSessionID: "thread", localSessionID: localID,
                                                     workspaceURL: URL(filePath: "/tmp"))
        try await adapter.send("Plan the change", to: handle)
        var turn = try await lastTurnStart(transport)
        XCTAssertEqual(turn.params["collaborationMode"]?["mode"], .string("plan"))

        try await adapter.selectCollaborationMode(plan, for: handle)
        _ = try await adapter.selectModel(.init(model: "gpt-test", reasoningEffort: "high"), for: handle)
        try await adapter.send("Plan more", to: handle)
        turn = try await lastTurnStart(transport)
        XCTAssertEqual(turn.params["collaborationMode"], .object([
            "mode": .string("plan"),
            "settings": .object(["model": .string("gpt-test"), "reasoning_effort": .string("high")])
        ]))
        await adapter.close(handle)
    }

    func testAStoredModeReadsBackAndAnUnknownOrEmptyValueIsNoMode() throws {
        let plan = CodexCollaborationPreset(name: "Plan", mode: "plan", model: "gpt-test", reasoningEffort: "high")
        let stored = try XCTUnwrap(plan.storedValue)
        XCTAssertEqual(CodexCollaborationPreset.restored(from: [CodexCollaborationPreset.storageKey: stored]), plan)
        XCTAssertNil(CodexCollaborationPreset.restored(from: [:]))
        XCTAssertNil(CodexCollaborationPreset.restored(from: [CodexCollaborationPreset.storageKey: ""]))
        XCTAssertNil(CodexCollaborationPreset.restored(from: [CodexCollaborationPreset.storageKey: "{\"name\":\"X\",\"mode\":\"pair\"}"]))
    }

    private func lastTurnStart(_ transport: FakeCodexTransport) async throws -> CodexRPCRequest {
        let requests = await transport.requests
        return try XCTUnwrap(requests.last { $0.method == "turn/start" })
    }

    private func selectedMode(_ model: AppModel, _ session: SessionRecord) -> String? {
        let state = model.codexCapabilitiesBySessionID[session.id] ?? .empty
        return state.modes.first { $0.id == state.selectedModeID }?.mode
    }

    private func composerMode(_ model: AppModel, _ session: SessionRecord) -> String? {
        guard let record = model.store.sessions.first(where: { $0.id == session.id }) else { return nil }
        let state = model.composerCodexCapabilities(for: record)
        return state.modes.first { $0.id == state.selectedModeID }?.mode
    }

    private func current(_ model: AppModel, _ session: SessionRecord) throws -> SessionRecord {
        try XCTUnwrap(model.store.sessions.first { $0.id == session.id })
    }
}

private actor ModeSaveGate {
    private(set) var failing = false
    func setFailing(_ value: Bool) { failing = value }
}

private struct ModeSaveFailure: LocalizedError {
    var errorDescription: String? { "The task could not be saved." }
}

/// Saves like the in-memory index, except a save that changes a task's Codex mode while the gate is
/// closed fails, as a full disk or a locked index would.
private actor ModeSaveFailingRepository: SessionRepository {
    private let storage: InMemorySessionRepository
    private let gate: ModeSaveGate
    private var savedModes: [UUID: String] = [:]

    init(sessions: [SessionRecord], gate: ModeSaveGate) {
        storage = InMemorySessionRepository(sessions: sessions)
        self.gate = gate
        for session in sessions { savedModes[session.id] = session.providerOptions[CodexCollaborationPreset.storageKey] }
    }

    func loadSessions() async throws -> [SessionRecord] { try await storage.loadSessions() }

    func upsert(_ session: SessionRecord) async throws {
        let mode = session.providerOptions[CodexCollaborationPreset.storageKey]
        if mode != savedModes[session.id], await gate.failing { throw ModeSaveFailure() }
        try await storage.upsert(session)
        savedModes[session.id] = mode
    }

    func archive(id: UUID) async throws { try await storage.archive(id: id) }
}
