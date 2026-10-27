import Foundation
import XCTest
@testable import NativeHarnessClient

/// Claude Code announces every permission-mode change on the stream as a `system` `status`
/// message, whatever changed it. The selector follows that announcement, so choosing an
/// approval's session mode switch moves it too. The frame shape is the one Claude Code 2.1.281
/// writes (`status: null`, `permissionMode`, `uuid`, `session_id`).
final class ClaudePermissionModeAnnouncementTests: XCTestCase {
    private let acceptEditsForSession: JSONValue = .object([
        "type": .string("setMode"),
        "mode": .string("acceptEdits"),
        "destination": .string("session")
    ])

    // MARK: - Reading the announcement

    func testTheAnnouncementIsReadInTheSelectorsOwnValue() {
        XCTAssertEqual(
            ClaudeProtocol.announcedPermissionMode(in: announcement("acceptEdits")),
            "acceptEdits"
        )
        XCTAssertEqual(ClaudeProtocol.announcedPermissionMode(in: announcement("plan")), "plan")
        // The CLI names Manual `default`; the selector's value for it is `manual`.
        XCTAssertEqual(ClaudeProtocol.announcedPermissionMode(in: announcement("default")), "manual")

        // A status message about something else, or another system message, is not one.
        XCTAssertNil(ClaudeProtocol.announcedPermissionMode(in: .object([
            "type": .string("system"),
            "subtype": .string("status"),
            "status": .string("compacting")
        ])))
        XCTAssertNil(ClaudeProtocol.announcedPermissionMode(in: .object([
            "type": .string("system"),
            "subtype": .string("init"),
            "permissionMode": .string("plan")
        ])))
    }

    /// Claude Code 2.1.281 answers `initialize` with `current_permission_mode`, spelled as its
    /// announcements spell it, and its schema names the model `current_model`. The keys earlier
    /// answers were read from are still accepted.
    func testTheInitializeAnswerIsReadInTheSelectorsOwnValue() {
        XCTAssertEqual(
            ClaudeProtocol.initialPermissionMode(in: .object([
                "current_permission_mode": .string("plan")
            ])),
            "plan"
        )
        XCTAssertEqual(
            ClaudeProtocol.initialPermissionMode(in: .object([
                "current_permission_mode": .string("default")
            ])),
            "manual"
        )
        XCTAssertEqual(
            ClaudeProtocol.initialPermissionMode(in: .object([
                "permissionMode": .string("acceptEdits")
            ])),
            "acceptEdits"
        )
        XCTAssertEqual(
            ClaudeProtocol.initialPermissionMode(in: .object([
                "permissionMode": .string("default")
            ])),
            "manual"
        )
        XCTAssertEqual(
            ClaudeProtocol.initialPermissionMode(in: .object([
                "current_permission_mode": .string("dontAsk"),
                "permissionMode": .string("plan")
            ])),
            "dontAsk"
        )
        XCTAssertNil(ClaudeProtocol.initialPermissionMode(in: .object([
            "current_permission_mode": .string("")
        ])))
        XCTAssertNil(ClaudeProtocol.initialPermissionMode(in: .object([:])))

        XCTAssertEqual(
            ClaudeProtocol.initialModel(in: .object(["current_model": .string("opus")])),
            "opus"
        )
        XCTAssertEqual(
            ClaudeProtocol.initialModel(in: .object(["model": .string("sonnet")])),
            "sonnet"
        )
        XCTAssertNil(ClaudeProtocol.initialModel(in: .object([:])))
    }

    // MARK: - Adapter

    /// A session that starts in a mode other than Manual, a resumed plan-mode session or a
    /// settings default, shows that mode from the handshake without waiting for an announcement.
    func testTheSelectorStartsInTheModeTheInitializeAnswerReports() async throws {
        for (reported, expected) in [("plan", "plan"), ("default", "manual")] {
            let transport = InitializeAnsweringClaudeTransport(response: Self.initializeAnswer(
                permissionMode: reported
            ))
            let adapter = ClaudeAdapter(
                executableURL: URL(filePath: "/tmp/fake-claude"),
                transportFactory: { _ in transport }
            )
            let handle = try await adapter.resumeSession(
                providerSessionID: "resumed-\(reported)",
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/tmp/workspace")
            )
            let mode = try await Self.mode(of: adapter, in: handle)
            XCTAssertEqual(mode, expected, reported)
            await adapter.close(handle)
        }

        let transport = InitializeAnsweringClaudeTransport(response: Self.initializeAnswer(
            permissionMode: "acceptEdits",
            model: "opus"
        ))
        let routed = YHPProviderCompatibilityAdapter(
            adapter: ClaudeAdapter(
                executableURL: URL(filePath: "/tmp/fake-claude"),
                transportFactory: { _ in transport }
            ),
            manifest: HarnessProtocolCompatibilityManifest.claude()
        )
        let handle = try await routed.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/tmp/workspace"),
                initialPrompt: nil
            )
        )
        let state = try await routed.providerCapabilities(for: handle)
        XCTAssertEqual(Self.permissionMode(in: state), "acceptEdits")
        XCTAssertEqual(state.selectors.first { $0.id == "model" }?.currentValue, "opus")
        await routed.close(handle)
    }

    func testTheApprovalsSessionModeSwitchMovesTheSelectorWhenTheCLIAnnouncesIt() async throws {
        let transport = FakeClaudeTransport()
        let adapter = ClaudeAdapter(
            executableURL: URL(filePath: "/tmp/fake-claude"),
            transportFactory: { _ in transport }
        )
        let handle = try await adapter.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/tmp/workspace"),
                initialPrompt: nil
            )
        )
        let recorder = ModeAnnouncementRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                await recorder.append(event.payload)
            }
        }
        defer { collector.cancel() }
        let initial = try await Self.mode(of: adapter, in: handle)
        XCTAssertEqual(initial, "manual")

        await transport.emit(canUseTool(requestID: "edit-1", suggestions: [acceptEditsForSession]))
        _ = try await waitForPermission(in: recorder, id: "edit-1")
        try await adapter.respond(to: "edit-1", selectedActionID: "allow_session", in: handle)
        // Sending the choice changes nothing by itself; the CLI's announcement is the fact.
        let afterChoice = try await Self.mode(of: adapter, in: handle)
        XCTAssertEqual(afterChoice, "manual")

        await transport.emit(announcement("acceptEdits"))
        try await waitForChangeCount(1, in: recorder)
        let announced = try await Self.mode(of: adapter, in: handle)
        XCTAssertEqual(announced, "acceptEdits")

        // The mode it already shows changes nothing and asks nobody to reread.
        await transport.emit(announcement("acceptEdits"))
        // Manual comes back as the selector's own value.
        await transport.emit(announcement("default"))
        try await waitForChangeCount(2, in: recorder)
        let manual = try await Self.mode(of: adapter, in: handle)
        XCTAssertEqual(manual, "manual")
        await adapter.close(handle)
    }

    func testAModeTheCLIAnnouncesBeforeItsHandshakeAnswersIsWhereTheSelectorStarts() async throws {
        let transport = HandshakeAnnouncingClaudeTransport(mode: "plan")
        let adapter = ClaudeAdapter(
            executableURL: URL(filePath: "/tmp/fake-claude"),
            transportFactory: { _ in transport }
        )
        let handle = try await adapter.resumeSession(
            providerSessionID: "resumed-in-plan",
            localSessionID: UUID(),
            workspaceURL: URL(filePath: "/tmp/workspace")
        )
        let resumed = try await Self.mode(of: adapter, in: handle)
        XCTAssertEqual(resumed, "plan")
        await adapter.close(handle)
    }

    // MARK: - The route the app ships

    func testTheAnnouncedModeCrossesTheYHPRouteTheAppShips() async throws {
        let transport = FakeClaudeTransport()
        let routed = YHPProviderCompatibilityAdapter(
            adapter: ClaudeAdapter(
                executableURL: URL(filePath: "/tmp/fake-claude"),
                transportFactory: { _ in transport }
            ),
            manifest: HarnessProtocolCompatibilityManifest.claude()
        )
        let handle = try await routed.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: "/tmp/workspace"),
                initialPrompt: nil
            )
        )
        let recorder = ModeAnnouncementRecorder()
        let collector = Task {
            for await event in await routed.events(for: handle) {
                await recorder.append(event.payload)
            }
        }
        defer { collector.cancel() }

        await transport.emit(announcement("acceptEdits"))
        try await waitForChangeCount(1, in: recorder)
        let routedMode = try await Self.mode(of: routed, in: handle)
        XCTAssertEqual(routedMode, "acceptEdits")
        await routed.close(handle)
    }

    @MainActor
    func testTheComposerSelectorFollowsTheApprovalsModeSwitchThroughTheAppModel() async throws {
        let runtime = try makeVersionFixtureRuntime(output: "2.1.281 (Claude Code)")
        defer { try? FileManager.default.removeItem(at: runtime.root) }
        let transport = FakeClaudeTransport()
        let routed = YHPProviderCompatibilityAdapter(
            adapter: ClaudeAdapter(
                executableURL: runtime.executable,
                transportFactory: { _ in transport }
            ),
            manifest: HarnessProtocolCompatibilityManifest.claude()
        )
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in routed }
        )
        await model.createSession(
            harness: .claudeCode,
            workspaceURL: URL(filePath: "/tmp/claude-mode-announcement"),
            runtimeExecutableURL: runtime.executable,
            title: "Mode announcement"
        )
        let session = try XCTUnwrap(model.store.selectedSession)
        await model.loadProviderCapabilities(for: session)
        XCTAssertEqual(
            model.providerCapabilitiesBySessionID[session.id].flatMap(Self.permissionMode(in:)),
            "manual"
        )

        await transport.emit(canUseTool(requestID: "edit-card", suggestions: [acceptEditsForSession]))
        var pending: PermissionRequest?
        let deadline = ContinuousClock.now + testWaitLimit
        while pending == nil, ContinuousClock.now < deadline {
            pending = model.transcriptBySessionID[session.id]?.lazy.compactMap { entry in
                guard case let .permission(request, .pending) = entry.content,
                      request.id == "edit-card" else { return nil }
                return request
            }.first
            if pending == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        let request = try XCTUnwrap(pending)
        let modeSwitch = try XCTUnwrap(request.actions.first { $0.id == "allow_session" })
        await model.respond(to: request.id, action: modeSwitch, in: session)
        await transport.emit(announcement("acceptEdits"))

        // No turn completes here; the selector follows the CLI while the turn is still running.
        let modeDeadline = ContinuousClock.now + testWaitLimit
        while ContinuousClock.now < modeDeadline,
              model.providerCapabilitiesBySessionID[session.id]
                .flatMap(Self.permissionMode(in:)) != "acceptEdits" {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(
            model.providerCapabilitiesBySessionID[session.id].flatMap(Self.permissionMode(in:)),
            "acceptEdits"
        )
        // The mode the approval switched to is the task's mode now. It is kept with the task, as
        // the Claude app keeps a session's mode, so the task resumes in it after a restart.
        let savedDeadline = ContinuousClock.now + testWaitLimit
        while ContinuousClock.now < savedDeadline,
              model.store.sessions.first(where: { $0.id == session.id })?.providerOptions["permissionMode"] == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.store.sessions.first { $0.id == session.id }?.providerOptions["permissionMode"], "acceptEdits")
        await model.shutdown()
    }

    // MARK: - Helpers

    private static func permissionMode(in state: ProviderCapabilityState) -> String? {
        state.selectors.first { $0.id == "permissionMode" }?.currentValue
    }

    private static func mode(
        of provider: any ProviderCapabilityProviding,
        in handle: HarnessSessionHandle
    ) async throws -> String? {
        permissionMode(in: try await provider.providerCapabilities(for: handle))
    }

    /// The keys of Claude Code 2.1.281's `initialize` answer that the selectors read. The
    /// stream-json route leaves `current_model` out; a Remote Control answer carries it.
    private static func initializeAnswer(permissionMode: String, model: String? = nil) -> JSONValue {
        var answer: [String: JSONValue] = [
            "models": .array([
                .object([
                    "value": .string("default"),
                    "displayName": .string("Default (recommended)"),
                    "description": .string("Use the default model")
                ]),
                .object([
                    "value": .string("opus"),
                    "displayName": .string("Opus"),
                    "description": .string("Opus for complex work")
                ])
            ]),
            "current_permission_mode": .string(permissionMode),
            "pid": .integer(4242)
        ]
        if let model { answer["current_model"] = .string(model) }
        return .object(answer)
    }

    private func announcement(_ mode: String) -> JSONValue {
        .object([
            "type": .string("system"),
            "subtype": .string("status"),
            "status": .null,
            "permissionMode": .string(mode),
            "uuid": .string(UUID().uuidString.lowercased()),
            "session_id": .string("claude-session")
        ])
    }

    private func canUseTool(requestID: String, suggestions: [JSONValue]) -> JSONValue {
        .object([
            "type": .string("control_request"),
            "request_id": .string(requestID),
            "request": .object([
                "subtype": .string("can_use_tool"),
                "tool_name": .string("Edit"),
                "input": .object(["file_path": .string("/tmp/workspace/notes.md")]),
                "tool_use_id": .string("toolu-\(requestID)"),
                "permission_suggestions": .array(suggestions)
            ])
        ])
    }

    private func waitForPermission(
        in recorder: ModeAnnouncementRecorder,
        id: String,
        timeout: Duration = testWaitLimit
    ) async throws -> PermissionRequest {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let request = await recorder.permission(id: id) { return request }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("no permission request arrived")
        throw HarnessAdapterError.invalidProviderEvent("no permission request arrived")
    }

    /// Waits for the given number of reread signals, then checks no other arrives on its heels.
    private func waitForChangeCount(
        _ count: Int,
        in recorder: ModeAnnouncementRecorder,
        timeout: Duration = testWaitLimit
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while await recorder.changeCount < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(50))
        let observed = await recorder.changeCount
        XCTAssertEqual(observed, count)
    }

    private func makeVersionFixtureRuntime(output: String) throws -> (root: URL, executable: URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "yardlet-claude-mode-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appending(path: "fixture-claude")
        let script = """
        #!/bin/sh
        printf '%s\\n' '\(output)'
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path(percentEncoded: false)
        )
        return (root, executable)
    }
}

private actor ModeAnnouncementRecorder {
    private var payloads: [HarnessEventPayload] = []

    func append(_ payload: HarnessEventPayload) { payloads.append(payload) }

    var changeCount: Int {
        payloads.filter { $0 == .providerCapabilitiesChanged }.count
    }

    func permission(id: String) -> PermissionRequest? {
        payloads.compactMap { payload -> PermissionRequest? in
            guard case let .permissionRequested(request) = payload,
                  request.id == id else { return nil }
            return request
        }.last
    }
}

/// A CLI whose `initialize` answer is the given one and that announces nothing.
private actor InitializeAnsweringClaudeTransport: ClaudeTransport {
    private let response: JSONValue
    private let stream: AsyncStream<ClaudeRawFrame>
    private let continuation: AsyncStream<ClaudeRawFrame>.Continuation

    init(response: JSONValue) {
        self.response = response
        let pair = AsyncStream<ClaudeRawFrame>.makeStream()
        self.stream = pair.stream
        self.continuation = pair.continuation
    }

    func start(_ configuration: ClaudeLaunchConfiguration) async throws {}

    func request(_ value: JSONValue, id: String) async throws -> JSONValue {
        value["request"]?["subtype"]?.stringValue == "initialize" ? response : .object([:])
    }

    func send(_ value: JSONValue) async throws {}

    func messages() async -> AsyncStream<ClaudeRawFrame> { stream }

    func stop() async { continuation.finish() }
}

/// A CLI that resumed into a mode and announces it before answering `initialize`, the order a
/// resumed plan-mode session can take.
private actor HandshakeAnnouncingClaudeTransport: ClaudeTransport {
    private let mode: String
    private let stream: AsyncStream<ClaudeRawFrame>
    private let continuation: AsyncStream<ClaudeRawFrame>.Continuation

    init(mode: String) {
        self.mode = mode
        let pair = AsyncStream<ClaudeRawFrame>.makeStream()
        self.stream = pair.stream
        self.continuation = pair.continuation
    }

    func start(_ configuration: ClaudeLaunchConfiguration) async throws {}

    func request(_ value: JSONValue, id: String) async throws -> JSONValue {
        guard value["request"]?["subtype"]?.stringValue == "initialize" else {
            return .object([:])
        }
        let frame: JSONValue = .object([
            "type": .string("system"),
            "subtype": .string("status"),
            "status": .null,
            "permissionMode": .string(mode),
            "uuid": .string(UUID().uuidString.lowercased()),
            "session_id": .string("resumed-in-plan")
        ])
        continuation.yield(ClaudeRawFrame(
            value: frame,
            data: (try? ClaudeWireCodec().encodeLine(frame)) ?? Data()
        ))
        // Answer only once the adapter has had the chance to read the announcement.
        try await Task.sleep(for: .milliseconds(100))
        return .object(["models": .array([])])
    }

    func send(_ value: JSONValue) async throws {}

    func messages() async -> AsyncStream<ClaudeRawFrame> { stream }

    func stop() async { continuation.finish() }
}
