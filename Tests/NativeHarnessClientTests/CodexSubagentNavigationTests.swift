import Foundation
import XCTest
@testable import NativeHarnessClient

@MainActor
final class CodexSubagentNavigationTests: XCTestCase {
    private func record(_ title: String, provider: String, scope: SessionEnvironmentScope = .native,
                        connection: ProviderConnection? = nil) -> SessionRecord {
        SessionRecord(harness: .codex, workspaceURL: URL(filePath: "/tmp/codex-subagent-project"),
                      runtimeExecutableURL: URL(filePath: "/tmp/fake-codex"), title: title,
                      providerSessionID: provider, environmentScope: scope, connection: connection)
    }

    private func account(_ name: String) -> ProviderConnection {
        ProviderConnection(id: name, name: name, harness: .codex, providerID: nil,
                           homePath: nil, credentialSelector: nil)
    }

    private func model(_ sessions: [SessionRecord], adapter: (any HarnessAdapter)? = nil,
                       projects: [Project] = [], presentation: [UUID: CodexTaskState] = [:],
                       visualFixture: Bool = false, repository: InMemorySessionRepository? = nil) throws -> AppModel {
        let suite = testDefaultsSuite("CodexSubagentNavigationTests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let adapter = adapter ?? FakeHarnessAdapter(kind: .codex)
        let model = AppModel(
            store: SessionStore(sessions: sessions, repository: repository ?? InMemorySessionRepository(sessions: sessions)),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false,
                                                     loadsPersistedSelections: false),
            registry: HarnessRegistry { _, _ in adapter },
            initialCodexPresentation: presentation,
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults),
            preferences: defaults,
            codexPendingRequestRepository: UserDefaultsCodexPendingServerRequestRepository(defaults: defaults),
            codexTimelineItemRepository: UserDefaultsCodexTimelineItemRepository(defaults: defaults),
            codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: defaults),
            transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults),
            projectRepository: InMemoryProjectRepository(snapshot: ProjectSnapshot(projects: projects)),
            sessionTitleResolver: { _ in nil }, restoresIndexOnLaunch: false, isVisualFixture: visualFixture)
        addTeardownBlock { @MainActor in await model.shutdown() }
        return model
    }

    func testExistingChildIsSelectedOnlyInTheParentsStorageScope() async throws {
        for scope in [SessionEnvironmentScope.native, .yardlet] {
            let parent = record("Parent", provider: "parent", scope: scope)
            let wrong = record("Other scope", provider: "child", scope: scope == .native ? .yardlet : .native)
            let correct = record("Same scope", provider: "child", scope: scope)
            try await assertReusesOnly(correct, parent: parent, wrong: wrong)
        }
    }

    func testExistingChildIsSelectedOnlyInTheParentsAccountIncludingTheDefaultAccount() async throws {
        for connection in [nil, account("account-a")] as [ProviderConnection?] {
            let parent = record("Parent", provider: "parent", connection: connection)
            let wrong = record("Other account", provider: "child", connection: account("account-b"))
            let correct = record("Same account", provider: "child", connection: connection)
            try await assertReusesOnly(correct, parent: parent, wrong: wrong)
        }
    }

    func testSameAccountIDDoesNotMakeDifferentSavedHomesTheSameStorage() async throws {
        let first = ProviderConnection(id: "account", name: "Account", harness: .codex, providerID: nil,
                                       homePath: "/tmp/codex-home-a", credentialSelector: nil)
        let second = ProviderConnection(id: "account", name: "Account", harness: .codex, providerID: nil,
                                        homePath: "/tmp/codex-home-b", credentialSelector: nil)
        let parent = record("Parent", provider: "parent", connection: first)
        let wrong = record("Other home", provider: "child", connection: second)
        let correct = record("Same home", provider: "child", connection: first)
        try await assertReusesOnly(correct, parent: parent, wrong: wrong)
    }

    private func assertReusesOnly(_ correct: SessionRecord, parent: SessionRecord, wrong: SessionRecord) async throws {
        let adapter = FakeHarnessAdapter(kind: .codex)
        let app = try model([parent, wrong, correct], adapter: adapter)
        app.composerDrafts.tasks.draft(for: wrong.id).text = "Keep this draft\n"
        let reading = app.taskWorkspaces.state(for: wrong.id).codex
        reading.bookmark = .init(anchorID: "saved-turn", fraction: 0.4, followsLatest: false)
        let bookmark = reading.bookmark
        await app.openCodexSubagent(threadID: "child", from: parent)
        XCTAssertEqual(app.store.selectedSessionID, correct.id)
        XCTAssertEqual(app.store.sessions.first { $0.id == wrong.id }, wrong)
        XCTAssertEqual(app.store.sessions.first { $0.id == correct.id }?.parentTaskID, parent.id)
        XCTAssertEqual(app.composerDrafts.tasks.draft(for: wrong.id).text, "Keep this draft\n")
        XCTAssertEqual(reading.bookmark, bookmark)
        XCTAssertEqual(app.store.sessions.count, 3)
        let resumes = await adapter.resumeCount
        XCTAssertEqual(resumes, 0, "Reusing a local record does not wake its provider")
    }

    func testForeignChildDoesNotPreventCreatingAChildInTheParentsScopeAndAccount() async throws {
        let parent = record("Parent", provider: "parent", scope: .yardlet, connection: account("a"))
        let wrong = record("Other storage", provider: "child", connection: account("b"))
        let adapter = FakeHarnessAdapter(kind: .codex)
        let app = try model([parent, wrong], adapter: adapter)
        await app.openCodexSubagent(threadID: "child", from: parent)
        let child = try XCTUnwrap(app.store.sessions.first { $0.id != wrong.id && $0.providerSessionID == "child" })
        XCTAssertEqual(child.environmentScope, parent.environmentScope)
        XCTAssertEqual(child.connection, parent.connection)
        XCTAssertEqual(child.parentTaskID, parent.id)
        XCTAssertEqual(app.store.sessions.first { $0.id == wrong.id }, wrong)
        let resumes = await adapter.resumeCount
        let submissions = await adapter.codexSubmissions
        XCTAssertEqual(resumes, 1)
        XCTAssertTrue(submissions.isEmpty)
    }

    func testProviderReportedParentIsResolvedWithinTheChildsStorage() async throws {
        let correct = record("Parent", provider: "parent", scope: .yardlet, connection: account("a"))
        let wrongScope = record("Other scope", provider: "parent", connection: account("a"))
        let wrongAccount = record("Other account", provider: "parent", scope: .yardlet, connection: account("b"))
        let child = record("Child", provider: "child", scope: .yardlet, connection: account("a"))
        var state = CodexTaskState.empty
        XCTAssertTrue(CodexTaskReducer().applySnapshot(.object([
            "id": .string("child"), "parentThreadId": .string("parent"), "turns": .array([])
        ]), to: &state))
        let app = try model([wrongScope, wrongAccount, correct, child], presentation: [child.id: state])
        try await waitUntil { app.store.sessions.first(where: { $0.id == child.id })?.parentTaskID != nil }
        XCTAssertEqual(app.store.sessions.first { $0.id == child.id }?.parentTaskID, correct.id)
    }

    func testStaleParentIdentityCannotOpenOrRelinkAChild() async throws {
        let stale = record("Parent", provider: "old-parent")
        var current = stale
        current.providerSessionID = "new-parent"
        let child = record("Child", provider: "child")
        let app = try model([current, child])
        let selection = app.store.selectedSessionID
        await app.openCodexSubagent(threadID: "child", from: stale)
        XCTAssertEqual(app.store.selectedSessionID, selection)
        XCTAssertEqual(app.store.sessions.first { $0.id == child.id }, child)
    }

    func testImportedChildUsesTheParentFromTheSelectedAccountAndNativeScope() async throws {
        let connection = account("a")
        let parent = record("Parent", provider: "parent", connection: connection)
        let wrongScope = record("Other scope", provider: "parent", scope: .yardlet, connection: connection)
        let wrongAccount = record("Other account", provider: "parent", connection: account("b"))
        let app = try model([wrongScope, wrongAccount, parent])
        app.runtimeSelections.select(URL(filePath: "/usr/bin/true"), for: .codex)
        let conversation = ImportableConversation(codex: CodexThreadSummary(
            id: "child", title: "Imported child", preview: "", workspaceURL: parent.workspaceURL,
            updatedAt: Date(), forkedFromID: "parent"))
        let result = await app.importConversation(conversation, connection: connection)
        let child = try XCTUnwrap(result)
        XCTAssertEqual(child.parentTaskID, parent.id)
        XCTAssertEqual(child.connection, connection)
        XCTAssertEqual(child.environmentScope, .native)
        XCTAssertEqual(app.store.sessions.first { $0.id == wrongScope.id }, wrongScope)
        XCTAssertEqual(app.store.sessions.first { $0.id == wrongAccount.id }, wrongAccount)
    }

    func testBulkParentLinksAndArchivedLookupKeepEachCodexStorageSeparate() {
        let nativeParent = record("Native parent", provider: "parent")
        let isolatedParent = record("Isolated parent", provider: "parent", scope: .yardlet)
        let accountParent = record("Account parent", provider: "parent", connection: account("a"))
        let nativeChild = record("Native child", provider: "child")
        let isolatedChild = record("Isolated child", provider: "child", scope: .yardlet)
        let accountChild = record("Account child", provider: "child", connection: account("a"))
        let sessions = [nativeParent, isolatedParent, accountParent, nativeChild, isolatedChild, accountChild]
        XCTAssertEqual(TaskLineage.links(parents: ["child": "parent"], harness: .codex, sessions: sessions),
                       [nativeChild.id: nativeParent.id, isolatedChild.id: isolatedParent.id, accountChild.id: accountParent.id])
        XCTAssertEqual(TaskLineage.task(continuing: "parent", harness: .codex,
                                       among: [nativeParent, isolatedParent], archived: [accountParent],
                                       environmentScope: .native, connection: account("a")), accountParent.id)
        XCTAssertNil(TaskLineage.task(continuing: "parent", harness: .codex,
                                     among: [isolatedParent, accountParent], environmentScope: .native))
    }

    func testParentChangingDuringResumeDiscardsOnlyTheNewChild() async throws {
        let parent = record("Parent", provider: "parent")
        let adapter = FakeHarnessAdapter(kind: .codex)
        let app = try model([parent], adapter: adapter)
        app.composerDrafts.tasks.draft(for: parent.id).text = "Parent draft"
        await adapter.suspendNextResumeSession()
        let opening = Task { await app.openCodexSubagent(threadID: "child", from: parent) }
        try await waitUntil { await adapter.isResumeBlocked }
        let blocked = await adapter.isResumeBlocked
        XCTAssertTrue(blocked)
        try await app.store.updateSession(id: parent.id, providerSessionID: "changed-parent", setProviderSessionID: true)
        await adapter.releaseSuspendedResumeSession()
        await opening.value
        XCTAssertEqual(app.store.sessions.map(\.id), [parent.id])
        XCTAssertEqual(app.store.sessions.first?.providerSessionID, "changed-parent")
        XCTAssertEqual(app.composerDrafts.tasks.draft(for: parent.id).text, "Parent draft")
        let closes = await adapter.closeCount
        let submissions = await adapter.codexSubmissions
        XCTAssertEqual(closes, 1)
        XCTAssertTrue(submissions.isEmpty)
    }

    func testVisualFixtureChildKeepsExplicitProjectAndAdditionalRoots() async throws {
        var parent = record("Parent", provider: "parent")
        parent.assignProject(UUID(), additionalRoots: ["/tmp/codex-subagent-extra"])
        let app = try model([parent], visualFixture: true)
        await app.openCodexSubagent(threadID: "child", from: parent)
        let child = try XCTUnwrap(app.store.sessions.first { $0.providerSessionID == "child" })
        XCTAssertEqual(child.projectID, parent.projectID)
        XCTAssertEqual(child.additionalRoots, parent.additionalRoots)
    }

    func testNewChildResumesWithProjectInstructionsAndRootsThroughTheProductAdapter() async throws {
        try await assertProductResume(projectDisabled: false)
    }

    func testNewChildRespectsItsProjectsDisabledInstructions() async throws {
        try await assertProductResume(projectDisabled: true)
    }

    private func assertProductResume(projectDisabled: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CodexSubagentNavigation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        // Only --version executes this fixture; every App Server request goes to FakeCodexTransport.
        let executable = root.appending(path: "codex")
        try "#!/bin/sh\nprintf 'codex-cli 0.163.0\\n'\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let project = Project(name: "Moved project", primaryRoot: root.appending(path: "new-project"))
        var parent = record("Parent moved to another project", provider: "parent", scope: .yardlet)
        parent.runtimeExecutableURL = executable
        parent.assignProject(project.id, additionalRoots: [project.primaryRoot.path])
        // The cwd belongs to no project, so missing explicit membership cannot be masked by folder lookup.
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "config/read": [.object(["config": .object(["developer_instructions": .string("Provider rules")])])],
            "thread/resume": [.object(["thread": .object(["id": .string("child"), "turns": .array([])])])]
        ])
        let adapter = YHPCodexCompatibilityAdapter(
            adapter: CodexAdapter(executableURL: executable, transport: transport),
            manifest: HarnessProtocolCompatibilityManifest.codex())
        let repository = InMemorySessionRepository(sessions: [parent])
        let app = try model([parent], adapter: adapter, projects: [project], repository: repository)
        let suite = testDefaultsSuite("CodexSubagentInstructions")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let instructions = YardletInstructionsStore(directory: root.appending(path: "instructions"), defaults: defaults)
        instructions.text = "Global rules"
        instructions.setProjectText("Project rules", for: project.id)
        instructions.setDisabled(projectDisabled, forProject: project.id)
        app.yardletInstructions = instructions
        let tools = RecordingToolLaunches()
        app.agentTools = tools
        app.composerDrafts.tasks.draft(for: parent.id).text = "Unsent parent draft"
        await app.openCodexSubagent(threadID: "child", from: parent)
        let child = try XCTUnwrap(app.store.sessions.first { $0.providerSessionID == "child" },
                                 app.errorBySessionID[parent.id] ?? "No child")
        XCTAssertEqual(child.projectID, project.id)
        XCTAssertEqual(child.additionalRoots, parent.additionalRoots)
        XCTAssertEqual(child.environmentScope, parent.environmentScope)
        XCTAssertEqual(child.parentTaskID, parent.id)
        let saved = try await repository.loadSessions()
        XCTAssertEqual(saved.first { $0.id == child.id }?.projectID, project.id)
        XCTAssertEqual(saved.first { $0.id == child.id }?.additionalRoots, parent.additionalRoots)
        let requests = await transport.requests
        let resume = try XCTUnwrap(requests.first { $0.method == "thread/resume" })
        let roots = [parent.workspaceURL.path] + parent.additionalRoots
        let requestedRoots = resume.params["runtimeWorkspaceRoots"]?.arrayValue?.compactMap(\.stringValue)
            .map { ProjectSidebarPresentation.normalizedPath(for: URL(filePath: $0)) }
        XCTAssertEqual(requestedRoots, roots)
        XCTAssertEqual(tools.roots[child.id]?.map { ProjectSidebarPresentation.normalizedPath(for: $0) }, roots)
        XCTAssertEqual(resume.params["threadId"]?.stringValue, "child")
        if projectDisabled {
            XCTAssertNil(resume.params["developerInstructions"])
        } else {
            XCTAssertEqual(resume.params["developerInstructions"]?.stringValue,
                           "Provider rules\n\nGlobal rules\n\nProject rules")
        }
        XCTAssertFalse(requests.contains { ["thread/start", "thread/fork", "turn/start"].contains($0.method) })
        XCTAssertEqual(app.composerDrafts.tasks.draft(for: parent.id).text, "Unsent parent draft")
    }

    private final class RecordingToolLaunches: AgentToolLaunchProviding {
        var roots: [UUID: [URL]] = [:]
        func agentToolServer(for localSessionID: UUID, workspaceRoots: [URL],
                             connectorScope: ConnectorTaskScope?) -> AgentToolServerLaunch? {
            roots[localSessionID] = workspaceRoots
            return AgentToolServerLaunch(command: "/tmp/fixture-yardlet-mcp", environment: [:])
        }
        func releaseAgentTools(for localSessionID: UUID) {}
    }
}
