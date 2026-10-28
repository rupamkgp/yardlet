import XCTest
@testable import NativeHarnessClient

@MainActor
final class PersonalAgentTests: XCTestCase {
    private func value(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    func testRoomMembershipSeparatesDotRepliesFromPeopleAndPaginationKeepsIdentity() throws {
        let agent = fixtureAgent()
        let room = try value(#"{"id":"room","aeon_id":"dot","members":[{"account_user_id":"person","name":"Person","role":"user"},{"account_user_id":"dot-member","name":"Atlas","role":"user","aeon_id":"dot"}]}"#)
        let page = try value(#"{"items":[{"id":"m1","role":"user","account_user_id":"person","created_at":"2026-10-01T09:00:00Z","content":{"text":"Prepare a draft.","attachments":[]}},{"id":"m2","role":"user","account_user_id":"dot-member","created_at":"2026-10-01T09:01:00Z","content":{"text":"The draft is ready.","attachments":[{"file":{"id":"report","file_name":"report.txt"}}]}}],"prev_cursor":null}"#)
        let result = try DotsProjection.messages(page, room: room, agent: agent)
        XCTAssertEqual(result.messages.map(\.author), [.person, .agent])
        XCTAssertEqual(result.before, "m1")
        XCTAssertEqual(result.messages[1].attachments, [.init(fileID: "report", name: "report.txt", type: "file")])
        let changedAccount = fixtureAgent(account: "different-account")
        XCTAssertNotEqual(agent.id, changedAccount.id)
        let wrongRoom = try value(#"{"id":"another-room","aeon_id":"dot","members":[]}"#)
        XCTAssertThrowsError(try DotsProjection.messages(page, room: wrongRoom, agent: agent))

        let edited = PersonalAgentMessage(id: "m2", author: .agent, text: "", createdAt: nil, isDeleted: true, attachments: [])
        let merged = DotsProjection.merge(result.messages, with: [edited], older: false)
        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged[1].isDeleted)
        XCTAssertEqual(merged[0].id, "m1")
    }

    func testLeavingAndReturningRetainsReadingPositionWithoutStartingAConversation() async throws {
        let center = PersonalAgentCenter()
        let agent = fixtureAgent()
        let reader = FixturePersonalAgentReader(agents: [agent])
        await center.connect(sourceKey: "saved-account") { reader }
        let state = try XCTUnwrap(center.conversation)
        state.anchor = "m1"
        await center.disconnect()
        XCTAssertEqual(center.selectedID, agent.id)
        XCTAssertEqual(center.conversation?.anchor, "m1")
        let stopped = await reader.didStop()
        XCTAssertTrue(stopped)
        let next = FixturePersonalAgentReader(agents: [agent])
        await center.connect(sourceKey: "saved-account") { next }
        XCTAssertEqual(center.conversation?.anchor, "m1")
        XCTAssertEqual(center.conversation?.messages.count, 1)
        await center.disconnect()
    }

    func testLateAccountReadCannotReplaceTheNewSelection() async {
        let center = PersonalAgentCenter()
        let delayed = FixturePersonalAgentReader(agents: [fixtureAgent()], delay: true)
        let pending = Task { await center.connect(sourceKey: "old") { delayed } }
        while !(await delayed.hasPendingRead()) { await Task.yield() }
        let replacement = fixtureAgent(account: "new-account")
        let next = FixturePersonalAgentReader(agents: [replacement])
        await center.connect(sourceKey: "new") { next }
        await delayed.release()
        await pending.value
        XCTAssertEqual(center.selectedID, replacement.id)
        await center.disconnect()
    }

    func testEarlierMessagesKeepTheCurrentReadingAnchor() async {
        let center = PersonalAgentCenter()
        let reader = FixturePersonalAgentReader(agents: [fixtureAgent()], paged: true)
        await center.connect(sourceKey: "account") { reader }
        center.conversation?.anchor = "m1"
        await center.refreshConversation(older: true)
        XCTAssertEqual(center.conversation?.messages.map(\.id), ["m0", "m1"])
        XCTAssertEqual(center.conversation?.anchor, "m1")
        XCTAssertNil(center.conversation?.before)
        await center.disconnect()
    }

    func testRefreshingAfterSeveralPagesOfUpdatesDoesNotLeaveAHole() async {
        let center = PersonalAgentCenter()
        let reader = FixturePersonalAgentReader(agents: [fixtureAgent()], gap: true)
        await center.connect(sourceKey: "account") { reader }
        center.conversation?.anchor = "m1"
        await reader.advance()
        await center.refreshConversation()
        XCTAssertEqual(center.conversation?.messages.map(\.id), ["m1", "m2", "m3"])
        XCTAssertEqual(center.conversation?.anchor, "m1")
        await center.disconnect()
    }

    func testUncertainDeliveryRetainsItsRequestAcrossRetryAndRefresh() async throws {
        let center = PersonalAgentCenter()
        let reader = FixturePersonalAgentReader(agents: [fixtureAgent()], losesFirstSend: true)
        await center.connect(sourceKey: "account") { reader }
        let draft = try XCTUnwrap(center.conversation?.draft)
        draft.editor.text = "Prepare a draft, without publishing it."
        await center.send()
        let pending = try XCTUnwrap(draft.pending)
        XCTAssertEqual(draft.failure, .deliveryUnknown)
        XCTAssertEqual(draft.editor.text, pending.text)
        // A rejected retry cannot prove that the earlier request was rejected.
        draft.failed(.signInRequired, retry: false)
        XCTAssertEqual(draft.pending, pending)
        draft.failed(.sendRejected, retry: true)
        XCTAssertEqual(draft.pending, pending)
        await center.send()
        let requests = await reader.sentRequests()
        XCTAssertEqual(requests.map(\.requestID), [pending.requestID, pending.requestID])
        XCTAssertTrue(draft.editor.text.isEmpty)
        XCTAssertNil(draft.pending)
        await center.disconnect()
    }

    func testSendingInOneAccountCannotClearAnotherAccountsDraftOrSendTwice() async throws {
        let drafts = PersonalAgentDrafts()
        let center = PersonalAgentCenter(drafts: drafts)
        let oldAgent = fixtureAgent()
        let old = FixturePersonalAgentReader(agents: [oldAgent], delaysSend: true)
        await center.connect(sourceKey: "old") { old }
        let oldDraft = try XCTUnwrap(center.conversation?.draft)
        oldDraft.editor.text = "Old account draft"
        let sending = Task { await center.send() }
        while !(await old.hasPendingSend()) { await Task.yield() }
        await center.send()
        let nextAgent = fixtureAgent(account: "another")
        let next = FixturePersonalAgentReader(agents: [nextAgent])
        await center.connect(sourceKey: "new") { next }
        center.conversation?.draft.editor.text = "Keep this new account draft"
        await old.releaseSend()
        await sending.value
        XCTAssertEqual(center.selectedID, nextAgent.id)
        XCTAssertEqual(center.conversation?.draft.editor.text, "Keep this new account draft")
        XCTAssertTrue(oldDraft.editor.text.isEmpty)
        let requests = await old.sentRequests()
        XCTAssertEqual(requests.count, 1)
        await center.connect(sourceKey: "old") { FixturePersonalAgentReader(agents: [oldAgent]) }
        XCTAssertTrue(center.conversation?.draft.editor.text.isEmpty == true)
        await center.connect(sourceKey: "new") { FixturePersonalAgentReader(agents: [nextAgent]) }
        XCTAssertEqual(center.conversation?.draft.editor.text, "Keep this new account draft")
        await center.disconnect()
    }

    func testOnlyTheSameAccountAndHomeRestoreAnUncertainDraft() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersonalAgentDrafts(directory: directory)
        let draft = store.draft(source: "home-a", identity: fixtureAgent().id)
        draft.editor.text = "A draft kept across restart"
        let request = try XCTUnwrap(draft.prepare())
        draft.failed(.deliveryUnknown, retry: false)
        let restored = PersonalAgentDrafts(directory: directory)
        let same = restored.draft(source: "home-a", identity: fixtureAgent().id)
        XCTAssertEqual(same.editor.text, request.text)
        XCTAssertEqual(same.prepare(), request)
        XCTAssertEqual(same.failure, .deliveryUnknown)
        same.failed(.verificationRequired, retry: true)
        same.isSending = true
        XCTAssertFalse(same.resumeEditing())
        XCTAssertEqual(same.pending, request)
        same.isSending = false
        XCTAssertTrue(same.resumeEditing())
        XCTAssertNil(same.pending)
        XCTAssertEqual(same.editor.text, request.text)
        let editable = PersonalAgentDrafts(directory: directory).draft(source: "home-a", identity: fixtureAgent().id)
        XCTAssertNil(editable.pending)
        XCTAssertEqual(editable.editor.text, request.text)
        XCTAssertNotEqual(editable.prepare()?.requestID, request.requestID)
        XCTAssertTrue(restored.draft(source: "home-b", identity: fixtureAgent().id).editor.text.isEmpty)
        XCTAssertTrue(restored.draft(source: "home-a", identity: fixtureAgent(account: "other").id).editor.text.isEmpty)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let corrupt = Data("unreadable draft".utf8)
        try corrupt.write(to: file)
        let broken = PersonalAgentDrafts(directory: directory).draft(source: "home-a", identity: fixtureAgent().id)
        broken.editor.text = "Must not overwrite the unreadable original"
        XCTAssertNil(broken.prepare())
        XCTAssertTrue(broken.storageFailed)
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
        XCTAssertTrue(broken.needsRecovery)
        XCTAssertTrue(broken.recoverStorage())
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.contains(".backup-") })
        XCTAssertEqual(try Data(contentsOf: backup), corrupt)
        let recovered = PersonalAgentDrafts(directory: directory).draft(source: "home-a", identity: fixtureAgent().id)
        XCTAssertFalse(recovered.needsRecovery)
        XCTAssertEqual(recovered.editor.text, "Must not overwrite the unreadable original")
        XCTAssertNil(recovered.pending)

        let blocker = directory.appending(path: "blocked")
        let recoverable = PersonalAgentDraft(file: blocker.appending(path: "draft.json"))
        try Data().write(to: blocker)
        recoverable.editor.text = "Save before sending"
        XCTAssertNil(recoverable.prepare())
        XCTAssertNil(recoverable.pending)
        try FileManager.default.removeItem(at: blocker)
        XCTAssertTrue(recoverable.save())
        XCTAssertNotNil(recoverable.prepare())
    }

    func testHistoryRefreshRevalidatesOldMessagesAndDoesNotUseASendAsItsBoundary() async throws {
        let center = PersonalAgentCenter()
        let reader = FixturePersonalAgentReader(agents: [fixtureAgent()])
        func message(_ id: String, _ text: String = "Earlier message") -> PersonalAgentMessage {
            .init(id: id, author: .agent, text: text, createdAt: nil, isDeleted: false, attachments: [])
        }
        await reader.replaceHistory([message("m1"), message("m2")])
        await center.connect(sourceKey: "runtime-a", draftSourceKey: "same-home") { reader }
        await center.refreshConversation(older: true)
        await reader.replaceHistory([message("m1", "Edited elsewhere"), message("m2"), message("m3"), message("m4")])
        center.conversation?.draft.editor.text = "A new message after the missing pages"
        await center.send()
        XCTAssertEqual(center.conversation?.messages.prefix(4).map(\.id), ["m1", "m2", "m3", "m4"])
        XCTAssertEqual(center.conversation?.messages.first?.text, "Edited elsewhere")
        XCTAssertEqual(center.conversation?.messages.last?.author, .person)
        XCTAssertTrue(center.conversation?.sentMessages.isEmpty == true)
        await reader.delayReadAfterNextSend()
        center.conversation?.draft.editor.text = "A message removed elsewhere before the first read"
        let sending = Task { await center.send() }
        while !(await reader.hasPendingMessageRead()) { await Task.yield() }
        XCTAssertFalse(center.conversation?.draft.isSending ?? true)
        center.conversation?.draft.editor.text = "The next draft remains editable during backfill"
        await reader.replaceHistory([message("m2"), message("m3"), message("m4")])
        await reader.releaseMessageRead()
        await sending.value
        XCTAssertEqual(center.conversation?.messages.map(\.id), ["m2", "m3", "m4"])
        XCTAssertEqual(center.conversation?.visibleMessages.map(\.id), ["m2", "m3", "m4"])
        XCTAssertEqual(center.conversation?.draft.editor.text, "The next draft remains editable during backfill")

        await reader.delayNextMessageRead()
        let refresh = Task { await center.refreshConversation() }
        while !(await reader.hasPendingMessageRead()) { await Task.yield() }
        refresh.cancel()
        await reader.releaseMessageRead()
        await refresh.value
        XCTAssertFalse(center.conversation?.isLoading ?? true)
        await center.refreshConversation()
        XCTAssertNil(center.conversation?.failure)

        center.conversation?.draft.editor.text = "Keep this when changing the runtime executable"
        await center.connect(sourceKey: "runtime-b", draftSourceKey: "same-home") {
            FixturePersonalAgentReader(agents: [fixtureAgent()])
        }
        XCTAssertEqual(center.conversation?.draft.editor.text, "Keep this when changing the runtime executable")
        await center.disconnect()
    }

    private func fixtureAgent(account: String = "account") -> PersonalAgent {
        .init(id: .init(accountID: account, userID: "person", agentID: "dot", roomID: "room"),
              name: "Atlas", rootThreadID: "thread", isPaused: false, isPrimary: true)
    }
}

private actor FixturePersonalAgentReader: PersonalAgentClient {
    let values: [PersonalAgent]
    let delay: Bool
    let paged: Bool
    let gap: Bool
    let losesFirstSend: Bool
    let delaysSend: Bool
    private var sends: [PersonalAgentSubmission] = []
    private var pendingSend: CheckedContinuation<Void, Never>?
    private var history: [PersonalAgentMessage]?
    private var delayMessageRead = false
    private var delayAfterSend = false
    private var pendingMessageRead: CheckedContinuation<Void, Never>?
    private var advanced = false
    private var pending: CheckedContinuation<[PersonalAgent], Never>?
    private var stopped = false
    init(agents: [PersonalAgent], delay: Bool = false, paged: Bool = false, gap: Bool = false,
         losesFirstSend: Bool = false, delaysSend: Bool = false) {
        values = agents; self.delay = delay; self.paged = paged; self.gap = gap
        self.losesFirstSend = losesFirstSend; self.delaysSend = delaysSend
    }
    func agents() async throws -> [PersonalAgent] {
        if delay { return await withCheckedContinuation { pending = $0 } }
        return values
    }
    func messages(for agent: PersonalAgent, before: String?) async throws -> PersonalAgentPage {
        if delayMessageRead {
            delayMessageRead = false
            await withCheckedContinuation { pendingMessageRead = $0 }
        }
        if let history {
            let end = before.flatMap { id in history.firstIndex { $0.id == id } } ?? history.count
            let start = max(0, end - 1)
            return .init(messages: Array(history[start..<end]), before: start > 0 ? history[start].id : nil)
        }
        if gap && advanced {
            let id = before == nil ? "m3" : before == "m3" ? "m2" : "m1"
            return .init(messages: [.init(id: id, author: .agent, text: "Draft ready.", createdAt: nil, isDeleted: false, attachments: [])],
                         before: id == "m1" ? nil : id)
        }
        return .init(messages: [.init(id: before == nil ? "m1" : "m0", author: .agent, text: "Draft ready.",
                               createdAt: nil, isDeleted: false, attachments: [])],
              before: paged && before == nil ? "m1" : nil)
    }
    func updates(for agent: PersonalAgent) async -> AsyncStream<PersonalAgentUpdate> { AsyncStream { $0.finish() } }
    func send(_ submission: PersonalAgentSubmission, to agent: PersonalAgent) async throws -> PersonalAgentMessage {
        sends.append(submission)
        if delaysSend { await withCheckedContinuation { pendingSend = $0 } }
        if losesFirstSend, sends.count == 1 { throw PersonalAgentFailure.deliveryUnknown }
        let message = PersonalAgentMessage(id: submission.requestID, author: .person, text: submission.text, createdAt: nil,
              isDeleted: false, attachments: [], requestID: submission.requestID)
        if history != nil { history?.append(message) }
        if delayAfterSend { delayMessageRead = true; delayAfterSend = false }
        return message
    }
    func download(_ attachment: PersonalAgentAttachment, for agent: PersonalAgent) async throws -> PersonalAgentDownload {
        throw PersonalAgentFailure.attachmentUnavailable
    }
    func stop() { stopped = true }
    func didStop() -> Bool { stopped }
    func hasPendingRead() -> Bool { pending != nil }
    func release() { pending?.resume(returning: values); pending = nil }
    func advance() { advanced = true }
    func sentRequests() -> [PersonalAgentSubmission] { sends }
    func hasPendingSend() -> Bool { pendingSend != nil }
    func releaseSend() { pendingSend?.resume(); pendingSend = nil }
    func replaceHistory(_ messages: [PersonalAgentMessage]) { history = messages }
    func delayNextMessageRead() { delayMessageRead = true }
    func delayReadAfterNextSend() { delayAfterSend = true }
    func hasPendingMessageRead() -> Bool { pendingMessageRead != nil }
    func releaseMessageRead() { pendingMessageRead?.resume(); pendingMessageRead = nil }
}
