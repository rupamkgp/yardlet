import XCTest
@testable import NativeHarnessClient

/// A thread Yardlet starts is named from its first request the way the official Codex app names
/// one: a short turn on an ephemeral read-only thread, then `thread/name/set`.
final class CodexThreadTitleTests: XCTestCase {
    private let request = "Run test_calc.py, find the failing tests, and fix calc.py."

    func testFirstRequestNamesTheThreadThroughAnEphemeralSideTurn() async throws {
        let transport = scriptedTransport(nameResponses: 1)
        let adapter = CodexAdapter(executableURL: URL(filePath: "/tmp/fake-codex"), transport: transport,
            namesNewThreads: true)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/yardlet-sandbox"), initialPrompt: request))

        try await waitUntil { await transport.requestMethods.filter { $0 == "turn/start" }.count == 2 }
        await finishSideTurn(on: transport, finalMessage: #"{"title":"Fix failing calc.py tests"}"#)
        try await waitUntil { await transport.requestMethods.contains("thread/name/set") }

        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.method), [
            "initialize", "thread/start", "turn/start",
            "model/list", "thread/start", "turn/start", "thread/unsubscribe", "thread/name/set"
        ])
        let sideThread = requests[4].params
        XCTAssertEqual(sideThread["ephemeral"]?.boolValue, true)
        XCTAssertEqual(sideThread["approvalPolicy"]?.stringValue, "never")
        XCTAssertEqual(sideThread["sandbox"]?.stringValue, "read-only")
        XCTAssertEqual(sideThread["cwd"]?.stringValue, "/tmp/yardlet-sandbox")
        XCTAssertEqual(sideThread["model"]?.stringValue, CodexThreadTitle.preferredModel)
        let sideTurn = requests[5].params
        XCTAssertEqual(sideTurn["threadId"]?.stringValue, "title-thread")
        XCTAssertNotNil(sideTurn["outputSchema"])
        XCTAssertTrue(sideTurn["input"]?.arrayValue?.first?["text"]?.stringValue?.contains(request) == true)
        XCTAssertEqual(requests[6].params["threadId"]?.stringValue, "title-thread")
        XCTAssertEqual(requests[7].params["threadId"]?.stringValue, "thread-1")
        XCTAssertEqual(requests[7].params["name"]?.stringValue, "Fix failing calc.py tests")

        let state = try await adapter.presentationState(for: handle)
        XCTAssertEqual(state.thread?.name, "Fix failing calc.py tests")
        XCTAssertFalse(state.thread?.turns.contains { $0.id == "title-turn" } ?? false,
            "The side turn never reaches the task's own timeline")
    }

    func testANameThePersonSetsMeanwhileIsKept() async throws {
        let transport = scriptedTransport(nameResponses: 1)
        let adapter = CodexAdapter(executableURL: URL(filePath: "/tmp/fake-codex"), transport: transport,
            namesNewThreads: true)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/workspace"), initialPrompt: request))
        try await waitUntil { await transport.requestMethods.filter { $0 == "turn/start" }.count == 2 }

        try await adapter.setThreadName("Calculator", for: handle)
        await finishSideTurn(on: transport, finalMessage: #"{"title":"Fix failing calc.py tests"}"#)
        try await waitUntil { await transport.requestMethods.contains("thread/unsubscribe") }
        try await Task.sleep(for: .milliseconds(50))

        let names = await transport.requests.filter { $0.method == "thread/name/set" }
        XCTAssertEqual(names.map { $0.params["name"]?.stringValue }, ["Calculator"])
    }

    func testFailedSideTurnLeavesTheThreadUnnamedAndLaterRequestsAlone() async throws {
        let transport = scriptedTransport(nameResponses: 0)
        await transport.enqueue(method: "turn/start", result: .object(["turn": .object(["id": .string("turn-2")])]))
        let adapter = CodexAdapter(executableURL: URL(filePath: "/tmp/fake-codex"), transport: transport,
            namesNewThreads: true)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/workspace"), initialPrompt: request))
        try await waitUntil { await transport.requestMethods.filter { $0 == "turn/start" }.count == 2 }

        await finishSideTurn(on: transport, finalMessage: nil, status: "failed")
        try await waitUntil { await transport.requestMethods.contains("thread/unsubscribe") }
        try await adapter.send("And add a test for division", to: handle)
        try await Task.sleep(for: .milliseconds(50))

        let methods = await transport.requestMethods
        XCTAssertFalse(methods.contains("thread/name/set"))
        XCTAssertEqual(methods.filter { $0 == "thread/start" }.count, 2, "Only the first request is used for a name")
    }

    func testThreadNameUpdatesReachThePresentationState() {
        let reducer = CodexTaskReducer()
        var state = CodexTaskState.empty
        XCTAssertTrue(reducer.applySnapshot(.object(["id": .string("thread-1"), "turns": .array([])]), to: &state))
        XCTAssertTrue(reducer.applyNotification(method: "thread/name/updated", params: .object([
            "threadId": .string("thread-1"), "threadName": .string("Fix calc tests")
        ]), sequence: 1, to: &state))
        XCTAssertEqual(state.thread?.name, "Fix calc tests")
        XCTAssertFalse(reducer.applyNotification(method: "thread/name/updated", params: .object([
            "threadId": .string("thread-1"), "threadName": .string("Fix calc tests")
        ]), sequence: 2, to: &state))
        XCTAssertTrue(reducer.applyNotification(method: "thread/name/updated", params: .object([
            "threadId": .string("thread-1"), "threadName": .null
        ]), sequence: 3, to: &state))
        XCTAssertNil(state.thread?.name)
    }

    func testTitleIsReadOnlyFromTheStructuredFinalMessage() {
        XCTAssertEqual(CodexThreadTitle.title(fromFinalMessage: #" {"title":"  Fix   calc tests "} "#), "Fix calc tests")
        XCTAssertNil(CodexThreadTitle.title(fromFinalMessage: "Fix calc tests"))
        XCTAssertNil(CodexThreadTitle.title(fromFinalMessage: #"{"title":"New task"}"#))
        XCTAssertNil(CodexThreadTitle.title(fromFinalMessage: nil))
        XCTAssertNil(CodexThreadTitle.request(from: [.localImage(URL(filePath: "/tmp/screen.png"))]))
        XCTAssertEqual(CodexThreadTitle.request(from: [.text("  Fix it \n")]), "Fix it")
    }

    // MARK: - Fixtures

    private func scriptedTransport(nameResponses: Int) -> FakeCodexTransport {
        FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [thread("thread-1"), thread("title-thread")],
            "turn/start": [turn("turn-1"), turn("title-turn")],
            "model/list": [.object(["data": .array([model("gpt-6-astra"), model(CodexThreadTitle.preferredModel)])])],
            "thread/unsubscribe": [.object([:])],
            "thread/name/set": Array(repeating: .object([:]), count: nameResponses)
        ])
    }

    private func finishSideTurn(on transport: FakeCodexTransport, finalMessage: String?, status: String = "completed") async {
        if let finalMessage {
            await transport.emit(method: "item/completed", params: .object([
                "threadId": .string("title-thread"), "turnId": .string("title-turn"),
                "item": .object(["id": .string("message"), "type": .string("agentMessage"), "text": .string(finalMessage)])
            ]))
        }
        await transport.emit(method: "turn/completed", params: .object([
            "threadId": .string("title-thread"),
            "turn": .object(["id": .string("title-turn"), "status": .string(status)])
        ]))
    }

    private func thread(_ id: String) -> JSONValue { .object(["thread": .object(["id": .string(id)])]) }

    private func turn(_ id: String) -> JSONValue { .object(["turn": .object(["id": .string(id)])]) }

    private func model(_ id: String) -> JSONValue {
        .object(["id": .string(id), "model": .string(id), "displayName": .string(id),
                 "defaultReasoningEffort": .string("medium"), "hidden": .bool(false)])
    }

    private func waitUntil(_ condition: @escaping () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not met")
    }
}
