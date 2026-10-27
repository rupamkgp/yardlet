import Foundation
import XCTest
@testable import NativeHarnessClient

@MainActor
final class ClaudeSubtaskAppModelTests: XCTestCase {
    func testReadingSavedChildDoesNotAttachCreateSelectOrChangeDrafts() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "child-model-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let parentID = UUID().uuidString.lowercased()
        let project = root.appending(path: "projects/project")
        let agents = project.appending(path: "\(parentID)/subagents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try Data().write(to: project.appending(path: "\(parentID).jsonl"))
        let frame = JSONValue.object(["type": .string("assistant"), "uuid": .string("answer"), "parentUuid": .null,
            "sessionId": .string(parentID), "message": .object(["content": .array([
                .object(["type": .string("text"), "text": .string("Original child answer")])])])])
        try JSONEncoder().encode(frame).write(to: agents.appending(path: "agent-original.jsonl"))
        let binding = ProviderConnection(id: "saved", name: "Saved", harness: .claudeCode, providerID: nil,
            homePath: root.path, credentialSelector: nil)
        let parent = SessionRecord(harness: .claudeCode, workspaceURL: root, runtimeExecutableURL: URL(filePath: "/tmp/fake"),
            title: "Parent", providerSessionID: parentID, environmentScope: .yardlet, connection: binding)
        let activity = HarnessActivity(id: "card", kind: "Agent", title: "Read", subtask: .init(agentID: "original"))
        let adapter = ChildReadSpyAdapter()
        let model = AppModel(store: SessionStore(sessions: [parent], repository: InMemorySessionRepository(sessions: [parent])),
            runtimeSelections: RuntimeSelectionStore(defaults: UserDefaults(suiteName: testDefaultsSuite("Child.Read"))!),
            registry: HarnessRegistry { _, _ in adapter },
            initialTranscripts: [parent.id: [.init(content: .activity(activity, state: .completed))]], restoresIndexOnLaunch: false)
        model.composerDrafts.tasks.draft(for: parent.id).text = "Unsent 👩🏽‍💻\n초안"
        let selection = model.store.selectedSessionID
        let records = model.store.sessions
        let transcript = model.transcriptBySessionID[parent.id]
        let snapshot = try await model.readClaudeSubtask(activityID: "card", from: parent)
        XCTAssertTrue(snapshot.entries.contains { if case .assistant("Original child answer", false) = $0.content { true } else { false } })
        XCTAssertEqual(model.store.sessions, records)
        XCTAssertEqual(model.store.selectedSessionID, selection)
        XCTAssertEqual(model.transcriptBySessionID[parent.id], transcript)
        XCTAssertEqual(model.composerDrafts.tasks.draft(for: parent.id).text, "Unsent 👩🏽‍💻\n초안")
        let created = await adapter.createCount, resumed = await adapter.resumeCount
        XCTAssertEqual(created, 0)
        XCTAssertEqual(resumed, 0)
        do { try await model.stopClaudeSubtask(activityID: "card", from: parent); XCTFail("Detached saved card stopped") }
        catch {}
        let wrongScope = SessionRecord(id: parent.id, harness: .claudeCode, workspaceURL: root,
            runtimeExecutableURL: parent.runtimeExecutableURL, title: parent.title, providerSessionID: parentID,
            environmentScope: .native, connection: binding)
        do { _ = try await model.readClaudeSubtask(activityID: "card", from: wrongScope); XCTFail("Wrong saved scope accepted") }
        catch {}
        await model.shutdown()
    }
}

private actor ChildReadSpyAdapter: HarnessAdapter {
    nonisolated let kind = HarnessKind.claudeCode
    private(set) var createCount = 0
    private(set) var resumeCount = 0
    func probeRuntime() throws -> HarnessRuntimeDescriptor { throw HarnessAdapterError.capabilityUnavailable("Unexpected runtime probe") }
    func createSession(_ request: CreateHarnessSessionRequest) throws -> HarnessSessionHandle {
        createCount += 1
        throw HarnessAdapterError.capabilityUnavailable("Unexpected session create")
    }
    func resumeSession(providerSessionID: String, localSessionID: UUID, workspaceURL: URL) throws -> HarnessSessionHandle {
        resumeCount += 1
        throw HarnessAdapterError.capabilityUnavailable("Unexpected session resume")
    }
    func send(_ prompt: String, to session: HarnessSessionHandle) throws { throw HarnessAdapterError.capabilityUnavailable("Unexpected model turn") }
    func interrupt(_ session: HarnessSessionHandle) throws { throw HarnessAdapterError.capabilityUnavailable("Unexpected interrupt") }
    func respond(to permissionRequestID: String, decision: PermissionDecision, in session: HarnessSessionHandle) throws {}
    func events(for session: HarnessSessionHandle) -> AsyncStream<HarnessEventEnvelope> { AsyncStream { $0.finish() } }
    func close(_ session: HarnessSessionHandle) {}
}
