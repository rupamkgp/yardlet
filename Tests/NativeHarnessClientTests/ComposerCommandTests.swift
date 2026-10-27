import Foundation
import XCTest
@testable import NativeHarnessClient

final class ComposerCommandTests: XCTestCase {
    func testProviderMetadataChoosesBuiltInNameAndKeepsAliasesAndArguments() throws {
        let rows = try decode(#"[{"name":"review","description":"Project review","argumentHint":"<file>"},{"name":"review","description":"Native review","argumentHint":"<target>","aliases":["check"],"builtin":true},{"name":"bad\nname"},{"name":"/bad"}]"#)
        let commands = ClaudeComposerCommands.decode(rows)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].description, "Native review")
        XCTAssertEqual(commands[0].argumentHint, "<target>")
        XCTAssertEqual(commands[0].aliases, ["check"])
    }

    func testCommandNamesTakePrecedenceOverAnAliasDuringSearch() {
        let alias = ProviderComposerCommand(name: "code-review", description: "Review code", argumentHint: "", aliases: ["review"])
        let exact = ProviderComposerCommand(name: "review", description: "Project command", argumentHint: "")
        XCTAssertEqual(ComposerCommands.matching([alias, exact], query: "review"), [exact, alias])
        XCTAssertEqual(ComposerCommands.matching([alias], query: "REV"), [alias])
        XCTAssertEqual(ComposerCommands.matching([alias], query: "Review code"), [alias])
    }

    func testOnlyAnUnfinishedLeadingSlashOpensSuggestions() {
        XCTAssertEqual(ComposerCommands.query(in: "/"), "")
        XCTAssertEqual(ComposerCommands.query(in: "  /plugin:review"), "plugin:review")
        for text in ["/review ", "/review args", "/review\n", "/tmp/file.swift", "Explain /review"] {
            XCTAssertNil(ComposerCommands.query(in: text), text)
        }
    }

    @MainActor
    func testSelectionPreservesUnsentTextAndAttachmentsAndDoesNotSubmit() {
        let draft = TaskComposerDraft()
        draft.text = "한글 👩🏽‍💻\n\nKeep  these spaces."
        draft.attachments = [.localImage(URL(filePath: "/tmp/image.png"), detail: .auto)]
        let attachments = draft.attachments
        draft.insertCommand(ProviderComposerCommand(name: "review", description: "", argumentHint: ""))
        XCTAssertEqual(draft.text, "/review 한글 👩🏽‍💻\n\nKeep  these spaces.")
        XCTAssertEqual(draft.attachments, attachments)
        XCTAssertEqual(draft.selection?.lowerBound, draft.text.endIndex)
    }

    func testReplacingAPrefixKeepsArgumentsAndDoesNotConsumeAFilePath() {
        let command = ProviderComposerCommand(name: "review", description: "", argumentHint: "")
        XCTAssertEqual(ComposerCommands.inserting(command, in: "/re"), "/review ")
        XCTAssertEqual(ComposerCommands.inserting(command, in: " \n /old  arg\nnext"), " \n /review  arg\nnext")
        XCTAssertEqual(ComposerCommands.inserting(command, in: "/tmp/file.swift"), "/review /tmp/file.swift")
        let invalid = ProviderComposerCommand(name: "a\nb", description: "", argumentHint: "")
        XCTAssertEqual(ComposerCommands.inserting(invalid, in: "Keep this"), "Keep this")
    }

    func testInitializerAndSystemInitHideTerminalAndKeepResetForClientRouting() throws {
        let response = try decode(#"{"commands":[{"name":"context","description":"Context","argumentHint":"","builtin":true},{"name":"color","builtin":true},{"name":"clear","aliases":["reset","new"],"builtin":true},{"name":"project:review","description":"Review","argumentHint":"<file>"}]}"#)
        let initial = ClaudeComposerCommands.initial(response)
        XCTAssertEqual(initial.map(\.name), ["context", "clear", "project:review"])
        let frame = try decode(#"{"type":"system","subtype":"init","slash_commands":["project:review","color","clear","new-skill"],"terminal_slash_commands":["color"]}"#)
        let refreshed = try XCTUnwrap(ClaudeComposerCommands.refreshed(initial, from: frame))
        XCTAssertEqual(refreshed.map(\.name), ["project:review", "clear", "new-skill"])
        XCTAssertEqual(refreshed[0].argumentHint, "<file>")
        let nested = try decode(#"{"type":"system","subtype":"init","parent_tool_use_id":"child","slash_commands":["hidden"]}"#)
        XCTAssertNil(ClaudeComposerCommands.refreshed(initial, from: nested))
    }

    func testSessionResetAliasesAreRefusedUnlessARealCommandOwnsThatName() throws {
        for text in ["/clear", "/reset args", " \n /new"] {
            XCTAssertThrowsError(try ClaudeComposerCommands.validateSubmission(text))
        }
        try ClaudeComposerCommands.validateSubmission("/new args", commands: [
            ProviderComposerCommand(name: "new", description: "Project command", argumentHint: "", builtin: false)
        ])
        try ClaudeComposerCommands.validateSubmission("Explain /clear")
    }

    func testOlderCompatibilityCatalogStillDecodesAndNewMetadataRoundTrips() throws {
        let old = try JSONDecoder().decode(HarnessProtocolSessionOptionCatalog.self, from: Data(
            #"{"options":[],"notes":[]}"#.utf8
        ))
        XCTAssertNil(old.composerCommands)
        let command = ProviderComposerCommand(name: "review", description: "Review", argumentHint: "<file>", aliases: ["check"])
        let catalog = HarnessProtocolSessionOptionCatalog(options: [], notes: [], composerCommands: [command])
        XCTAssertEqual(try JSONDecoder().decode(HarnessProtocolSessionOptionCatalog.self, from: JSONEncoder().encode(catalog)), catalog)
    }

    func testProviderLocalOutputIsDisplayedWithoutBeingDroppedOrClaimedAsModelText() throws {
        let frame = try decode(#"{"type":"system","subtype":"local_command_output","uuid":"local-1","content":"Command completed"}"#)
        var projection = ClaudeSessionProjection()
        let payloads = projection.payloads(from: frame)
        guard case let .activityCompleted(activity) = payloads.first else { return XCTFail("Missing local output") }
        XCTAssertEqual(activity.output, "Command completed")
        XCTAssertEqual(activity.kind, "command")
        XCTAssertFalse(payloads.contains(.assistantMessageCompleted("Command completed")))
    }

    func testProductRouteLoadsCommandsWithoutSendingAndForwardsExplicitInvocationExactly() async throws {
        let response = try decode(#"{"models":[],"commands":[{"name":"code-review","description":"Review","argumentHint":"<target>","aliases":["review"],"builtin":true}]}"#)
        let transport = FakeClaudeTransport(initializeResponse: response)
        let adapter = YHPProviderCompatibilityAdapter(
            adapter: ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"), transportFactory: { _ in transport }),
            manifest: HarnessProtocolCompatibilityManifest.claude()
        )
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/commands"), initialPrompt: nil
        ))
        let state = try await adapter.providerCapabilities(for: handle)
        XCTAssertEqual(state.composerCommands.first?.aliases, ["review"])
        XCTAssertEqual(state.composerCommands.first?.argumentHint, "<target>")
        let before = await transport.sentValues
        XCTAssertTrue(before.isEmpty)
        _ = try await adapter.setProviderOption(id: "model", value: "opus", in: handle)
        let updated = try await adapter.providerCapabilities(for: handle)
        XCTAssertEqual(updated.composerCommands, state.composerCommands)
        try await adapter.send("/code-review 한글\nKeep  spaces", to: handle)
        let sent = await transport.sentValues
        XCTAssertEqual(sent.last?["message"]?["content"]?.stringValue, "/code-review 한글\nKeep  spaces")
        await adapter.close(handle)
    }

    func testProviderInitUpdatesTheProductCatalogAndKeepsItsSessionIdentity() async throws {
        let transport = FakeClaudeTransport(initializeResponse: try decode(#"{"commands":[{"name":"review","description":"Review","argumentHint":"<file>"}]}"#))
        let adapter = ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"), transportFactory: { _ in transport })
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/commands"), initialPrompt: nil
        ))
        let changed = expectation(description: "provider command catalog changed")
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                if event.payload == .providerCapabilitiesChanged { changed.fulfill(); break }
            }
        }
        await transport.emit(try decode(#"{"type":"system","subtype":"init","slash_commands":["review","fresh","color"],"terminal_slash_commands":["color"]}"#))
        await fulfillment(of: [changed], timeout: 2)
        collector.cancel()
        let state = try await adapter.providerCapabilities(for: handle)
        XCTAssertEqual(state.composerCommands.map(\.name), ["review", "fresh"])
        XCTAssertEqual(state.composerCommands[0].argumentHint, "<file>")
        let sent = await transport.sentValues
        XCTAssertTrue(sent.isEmpty)
        await adapter.close(handle)
    }

    func testUnsupportedResetIsRefusedBeforeProviderDispatch() async throws {
        let transport = FakeClaudeTransport()
        let adapter = ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"), transportFactory: { _ in transport })
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/commands"), initialPrompt: nil
        ))
        for text in ["/clear", "/reset", "/new"] {
            do { try await adapter.send(text, to: handle); XCTFail("Reset reached the provider") }
            catch let error as HarnessAdapterError {
                guard case .capabilityUnavailable = error else { return XCTFail("Wrong reset refusal") }
            }
        }
        let sent = await transport.sentValues
        XCTAssertTrue(sent.isEmpty)
        _ = try await adapter.providerCapabilities(for: handle)
        await adapter.close(handle)
    }

    func testHomeLookupCreatesNoPromptAndClosesOnlyItsTemporaryHandle() async throws {
        let response = try decode(#"{"commands":[{"name":"review","description":"Review","argumentHint":"<file>"}]}"#)
        let transport = FakeClaudeTransport(initializeResponse: response)
        let adapter = ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"), transportFactory: { _ in transport })
        let commands = try await ComposerCommandReader.read(using: adapter, workspaceURL: URL(filePath: "/tmp/home-command-project"))
        XCTAssertEqual(commands.map(\.name), ["review"])
        let sent = await transport.sentValues
        let requestTypes = await transport.requestSubtypes
        let stopped = await transport.stopCount
        let configuration = await transport.configuration
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(requestTypes, ["initialize"])
        XCTAssertEqual(stopped, 1)
        XCTAssertEqual(configuration?.resumesExistingSession, false)
        XCTAssertEqual(configuration?.workspaceURL, URL(filePath: "/tmp/home-command-project"))
    }

    func testHomeLookupInitializationFailureClosesTheProbeWithoutSending() async throws {
        let transport = FakeClaudeTransport(initializeResponse: .string("invalid handshake"))
        let adapter = ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"), transportFactory: { _ in transport })
        do {
            _ = try await ComposerCommandReader.read(using: adapter, workspaceURL: URL(filePath: "/tmp/commands"))
            XCTFail("Malformed initialization was accepted")
        } catch {}
        let sent = await transport.sentValues
        let stopped = await transport.stopCount
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(stopped, 1)
    }

    @MainActor
    func testHomeMetadataLookupKeepsTheAppIndexDraftAndExistingSessionUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "command-model-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appending(path: "claude")
        try Data("#!/bin/sh\nprintf '2.1.284 (Claude Code)\\n'\n".utf8).write(to: runtime)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)
        let transport = FakeClaudeTransport(initializeResponse: try decode(#"{"commands":[{"name":"review","description":"Review","argumentHint":""}]}"#))
        let adapter = ClaudeAdapter(executableURL: runtime, transportFactory: { _ in transport })
        let session = SessionRecord(harness: .claudeCode, workspaceURL: root, runtimeExecutableURL: runtime,
                                    title: "Existing", providerSessionID: "saved-provider-id")
        let suite = testDefaultsSuite("CommandHome")
        let defaults = UserDefaults(suiteName: suite)!
        let model = AppModel(
            store: SessionStore(sessions: [session], repository: InMemorySessionRepository(sessions: [session])),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false, loadsPersistedSelections: false),
            registry: HarnessRegistry { _, _ in adapter },
            composerDraftRepository: InMemoryComposerDraftRepository(), restoresIndexOnLaunch: false
        )
        model.composerDrafts.home.text = "Keep this unsent"
        let before = model.store.sessions
        let commands = try await model.readHomeComposerCommands(workspaceURL: root, runtimeURL: runtime, connection: nil)
        XCTAssertEqual(commands.map(\.name), ["review"])
        XCTAssertEqual(model.store.sessions, before)
        XCTAssertEqual(model.store.sessions.first?.providerSessionID, "saved-provider-id")
        XCTAssertEqual(model.composerDrafts.home.text, "Keep this unsent")
        XCTAssertFalse(model.isAttached(session.id))
        let sent = await transport.sentValues
        XCTAssertTrue(sent.isEmpty)
    }

    @MainActor
    func testHomeCommandSelectionPreservesTheProjectAndDoesNotBeginCreation() {
        let draft = NewTaskDraft()
        draft.text = "검토\n한글 👩🏽‍💻"
        draft.workspaceURL = URL(filePath: "/tmp/project")
        draft.harness = .claudeCode
        let projectID = UUID()
        draft.projectID = projectID
        draft.insertCommand(ProviderComposerCommand(name: "review", description: "", argumentHint: ""))
        XCTAssertEqual(draft.text, "/review 검토\n한글 👩🏽‍💻")
        XCTAssertEqual(draft.workspaceURL, URL(filePath: "/tmp/project"))
        XCTAssertEqual(draft.projectID, projectID)
        XCTAssertEqual(draft.harness, .claudeCode)
        XCTAssertFalse(draft.isCreating)
    }

    private func decode(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }
}
