import Foundation
import XCTest
@testable import YardletRemote

/// The remote server over channels the test holds (no sockets): authentication refuses everything
/// but a paired token or an open pairing, a pairing works once and not after it expires or after
/// wrong codes, snapshots and their change and attention events, conversation pages and changes, and
/// commands reaching the bridge with their audit lines — never the message text.
final class RemoteServerTests: XCTestCase {
    func testAConnectionMustAuthenticateFirst() async throws {
        let harness = try await ServerHarness()
        let channel = await harness.connect()
        await harness.send(#"{"id":"1","type":"snapshot"}"#, on: channel)
        let response = try await channel.response("1")
        XCTAssertEqual(response.error?.code, .unauthenticated)
        try await channel.waitUntilClosed(.unauthenticated)

        let garbage = await harness.connect()
        await harness.send("{", on: garbage)
        try await garbage.waitUntilClosed(.unauthenticated)
    }

    func testAWrongOrMissingTokenIsRefused() async throws {
        let harness = try await ServerHarness()
        let wrong = await harness.connect()
        await harness.send(#"{"id":"1","type":"hello","protocolVersion":1,"token":"not-a-device"}"#, on: wrong)
        let awaited1 = try await wrong.response("1").error?.code
        XCTAssertEqual(awaited1, .invalidToken)
        try await wrong.waitUntilClosed(.unauthenticated)

        let missing = await harness.connect()
        await harness.send(#"{"id":"2","type":"hello","protocolVersion":1}"#, on: missing)
        let awaited2 = try await missing.response("2").error?.code
        XCTAssertEqual(awaited2, .badRequest)
        try await missing.waitUntilClosed(.unauthenticated)

        let future = await harness.connect()
        let (_, token) = await harness.devices.add(name: "Pixel")
        await harness.send(#"{"id":"3","type":"hello","protocolVersion":2,"token":"\#(token)"}"#, on: future)
        let awaited3 = try await future.response("3").error?.code
        XCTAssertEqual(awaited3, .unsupportedVersion)
        try await future.waitUntilClosed(.unsupportedVersion)
    }

    func testAPairingWorksOnceAndItsTokenThenAuthenticates() async throws {
        let harness = try await ServerHarness()
        let ticket = await harness.server.openPairing()
        let phone = await harness.connect()
        await harness.send(#"{"id":"1","type":"pair","protocolVersion":1,"code":"\#(ticket.displayCode.lowercased())","deviceName":"Pixel 9"}"#, on: phone)
        let paired = try await phone.response("1")
        XCTAssertTrue(paired.ok)
        let token = try XCTUnwrap(paired.token)
        XCTAssertEqual(paired.server?.protocolVersion, 1)
        // Authenticated by the pairing itself.
        await harness.send(#"{"id":"2","type":"ping"}"#, on: phone)
        let awaited4 = try await phone.response("2").pong
        XCTAssertEqual(awaited4, true)

        // Reused: the secret is spent.
        let second = await harness.connect()
        await harness.send(#"{"id":"1","type":"pair","protocolVersion":1,"code":"\#(ticket.code)","deviceName":"Other"}"#, on: second)
        let awaited5 = try await second.response("1").error?.code
        XCTAssertEqual(awaited5, .pairingUnavailable)

        XCTAssertEqual(paired.serverTime, RemoteJSON.milliseconds(RemoteTestClock().now))
        let later = await harness.connect()
        await harness.send(#"{"id":"1","type":"hello","protocolVersion":1,"token":"\#(token)"}"#, on: later)
        let hello = try await later.response("1")
        XCTAssertTrue(hello.ok)
        XCTAssertEqual(hello.serverTime, RemoteJSON.milliseconds(RemoteTestClock().now))
        XCTAssertEqual(hello.deviceId, paired.deviceId)
        let devices = await harness.devices.all()
        XCTAssertEqual(devices.map(\.name), ["Pixel 9"])
        let status = await harness.server.status
        XCTAssertEqual(status.pairedDeviceID, paired.deviceId)
        XCTAssertNil(status.pairing)
    }

    func testAnExpiredPairingIsRefused() async throws {
        let clock = RemoteTestClock()
        let harness = try await ServerHarness(clock: clock)
        let ticket = await harness.server.openPairing(lifetime: 300)
        clock.advance(by: 301)
        let phone = await harness.connect()
        await harness.send(#"{"id":"1","type":"pair","protocolVersion":1,"code":"\#(ticket.code)","deviceName":"Pixel"}"#, on: phone)
        let awaited6 = try await phone.response("1").error?.code
        XCTAssertEqual(awaited6, .pairingUnavailable)
        let devices = await harness.devices.all()
        XCTAssertTrue(devices.isEmpty)
    }

    func testWrongCodesCloseThePairing() async throws {
        let harness = try await ServerHarness()
        let ticket = await harness.server.openPairing()
        let phone = await harness.connect()
        for attempt in 1...5 {
            await harness.send(#"{"id":"\#(attempt)","type":"pair","protocolVersion":1,"code":"00000-00000","deviceName":"Guess"}"#, on: phone)
            let awaited7 = try await phone.response("\(attempt)").error?.code
            XCTAssertEqual(awaited7, .pairingInvalid)
        }
        await harness.send(#"{"id":"6","type":"pair","protocolVersion":1,"code":"\#(ticket.code)","deviceName":"Late"}"#, on: phone)
        let awaited8 = try await phone.response("6").error?.code
        XCTAssertEqual(awaited8, .pairingUnavailable)
        let audit = harness.audit.entries().map(\.result)
        XCTAssertEqual(audit.filter { $0 == "pairingInvalid" }.count, 5)
    }

    func testUnauthenticatedAndQuietConnectionsAreClosed() async throws {
        let clock = RemoteTestClock()
        let harness = try await ServerHarness(clock: clock)
        let silent = await harness.connect()
        let phone = try await harness.authenticatedPhone()
        clock.advance(by: 11)
        await harness.server.sweep()
        try await silent.waitUntilClosed(.idle)
        XCTAssertFalse(phone.isClosed)
        clock.advance(by: 80)
        await harness.server.sweep()
        try await phone.waitUntilClosed(.idle)
    }

    func testTheSnapshotThenItsChangesAndAttention() async throws {
        let harness = try await ServerHarness()
        let phone = try await harness.authenticatedPhone()
        await harness.send(#"{"id":"s","type":"snapshot"}"#, on: phone)
        let snapshot = try await phone.response("s")
        XCTAssertEqual(snapshot.tasks?.map(\.id), ["A", "B"])
        XCTAssertEqual(snapshot.projects?.map(\.name), ["Yardlet"])
        XCTAssertEqual(snapshot.serverTime, RemoteJSON.milliseconds(RemoteTestClock().now), "The phone corrects for clock skew")

        var next = FakeBridge.snapshot
        next.tasks[0].attention = .waiting
        next.tasks[0].indicator = .awaitingApproval
        next.tasks[0].pendingRequest = .approval
        next.newestRequestIDs["A"] = "toolu_1"
        next.requestSummaries["A"] = "Bash: Run the migration tests"
        next.tasks.remove(at: 1)
        await harness.bridge.setSnapshot(next)
        await harness.bridge.signal(.tasks)

        let changed = try await phone.event(.tasksChanged)
        XCTAssertEqual(changed.tasks?.map(\.id), ["A"])
        XCTAssertEqual(changed.removedTaskIds, ["B"])
        XCTAssertNil(changed.projects)
        let attention = try await phone.event(.attention)
        XCTAssertEqual(attention.taskId, "A")
        XCTAssertEqual(attention.state, .waiting)
        XCTAssertEqual(attention.previousState, .active)
        XCTAssertEqual(attention.requestId, "toolu_1")
        XCTAssertEqual(attention.summary, "Bash: Run the migration tests")
        XCTAssertEqual(attention.projectName, "Yardlet")

        // A second request in a task that already waits is news too.
        next.newestRequestIDs["A"] = "toolu_2"
        await harness.bridge.setSnapshot(next)
        await harness.bridge.signal(.tasks)
        let awaited9 = try await phone.event(.attention, after: attention.seq ?? 0).requestId
        XCTAssertEqual(awaited9, "toolu_2")
    }

    func testAConversationPagesAndFollowsItsChanges() async throws {
        let harness = try await ServerHarness()
        let phone = try await harness.authenticatedPhone()
        var turns = (1...14).map { RemoteProtocolTests.turn("t\($0)", items: 3) }
        await harness.bridge.setConversation(RemoteConversation(turns: turns), for: "A")

        await harness.send(#"{"id":"1","type":"subscribeTask","taskId":"A"}"#, on: phone)
        let page = try await phone.response("1")
        var client = try XCTUnwrap(page.items)
        XCTAssertEqual(client.first?.turnId, "t5")
        XCTAssertEqual(page.hasOlder, true)
        let watched = await harness.bridge.watchedTasks
        XCTAssertEqual(watched, ["A"])
        let prepared = await harness.bridge.preparedTasks
        XCTAssertEqual(prepared, ["A"])

        await harness.send(#"{"id":"2","type":"loadOlder","taskId":"A","cursor":"\#(page.cursor ?? "")"}"#, on: phone)
        let older = try await phone.response("2")
        XCTAssertEqual(older.items?.first?.turnId, "t1")
        XCTAssertEqual(older.hasOlder, false)
        client = (older.items ?? []) + client

        turns[13].items[2].text = "streaming…"
        turns.append(RemoteProtocolTests.turn("t15", items: 2))
        await harness.bridge.setConversation(RemoteConversation(turns: turns), for: "A")
        await harness.bridge.signal(.conversation("A"))
        let delta = try await phone.event(.conversation)
        client = RemoteProtocolTests.strictlyApplying(delta.changes ?? [], to: client)
        XCTAssertEqual(client, turns.flatMap(\.items))

        await harness.send(#"{"id":"3","type":"loadOlder","taskId":"A","cursor":"stale"}"#, on: phone)
        let awaited10 = try await phone.response("3").error?.code
        XCTAssertEqual(awaited10, .invalidCursor)

        await harness.bridge.setConversation(nil, for: "A")
        await harness.bridge.signal(.conversation("A"))
        let awaited11 = try await phone.event(.conversationEnded).reason
        XCTAssertEqual(awaited11, "removed")
        await harness.send(#"{"id":"4","type":"subscribeTask","taskId":"missing"}"#, on: phone)
        let awaited12 = try await phone.response("4").error?.code
        XCTAssertEqual(awaited12, .notFound)
    }

    /// A change read while older turns load is not lost: the page goes first, then the changes to the
    /// newer turns, and every change names only items the phone holds by then.
    func testAChangeReadWhileOlderTurnsLoadFollowsThePage() async throws {
        let harness = try await ServerHarness()
        let phone = try await harness.authenticatedPhone()
        var turns = (1...14).map { RemoteProtocolTests.turn("t\($0)", items: 3) }
        await harness.bridge.setConversation(RemoteConversation(turns: turns), for: "A")
        await harness.send(#"{"id":"1","type":"subscribeTask","taskId":"A"}"#, on: phone)
        let page = try await phone.response("1")
        // The conversation moves on, and the phone asks for older turns before the change is told.
        turns[13].items[1].text = "changed while loading"
        turns[13].items.insert(RemoteProtocolTests.item("i:new-before-answer"), at: 2)
        turns.append(RemoteProtocolTests.turn("t15", items: 2))
        await harness.bridge.setConversation(RemoteConversation(turns: turns), for: "A")
        await harness.send(#"{"id":"2","type":"loadOlder","taskId":"A","cursor":"\#(page.cursor ?? "")"}"#, on: phone)
        let older = try await phone.response("2")
        let changes = try await phone.event(.conversation)
        var client = (older.items ?? []) + (page.items ?? [])
        client = RemoteProtocolTests.strictlyApplying(changes.changes ?? [], to: client)
        XCTAssertEqual(client, turns.flatMap(\.items))
        // The change signal arriving late finds nothing more to send.
        await harness.bridge.signal(.conversation("A"))
        do {
            let after = try await phone.event(.conversation, after: changes.seq ?? 0, timeout: 0.3)
            XCTFail("Unexpected second change: \(after)")
        } catch is TestChannel.TimedOut {}
    }

    func testOlderTurnsTheProviderHoldsAreAskedFor() async throws {
        let harness = try await ServerHarness()
        let phone = try await harness.authenticatedPhone()
        let held = (1...3).map { RemoteProtocolTests.turn("h\($0)", items: 2) }
        let loaded = (1...2).map { RemoteProtocolTests.turn("t\($0)", items: 2) }
        await harness.bridge.setConversation(RemoteConversation(turns: loaded, hasEarlier: true), for: "A")
        await harness.bridge.setEarlier(RemoteConversation(turns: held + loaded), for: "A")
        await harness.send(#"{"id":"1","type":"subscribeTask","taskId":"A"}"#, on: phone)
        let page = try await phone.response("1")
        XCTAssertEqual(page.cursor, "t:t1")
        await harness.send(#"{"id":"2","type":"loadOlder","taskId":"A","cursor":"t:t1"}"#, on: phone)
        let older = try await phone.response("2")
        XCTAssertEqual(older.items?.map(\.turnId).first, "h1")
        XCTAssertEqual(older.hasOlder, false)
    }

    func testCommandsReachTheBridgeAndTheAuditLogKeepsNoText() async throws {
        let harness = try await ServerHarness()
        let phone = try await harness.authenticatedPhone()
        await harness.send(#"{"id":"1","type":"sendMessage","taskId":"A","text":"  Secret plan: ship it  "}"#, on: phone)
        let awaited13 = try await phone.response("1").ok
        XCTAssertTrue(awaited13)
        await harness.send(#"{"id":"2","type":"answerApproval","taskId":"A","requestId":"toolu_1","answer":"deny"}"#, on: phone)
        let awaited14 = try await phone.response("2").ok
        XCTAssertTrue(awaited14)
        await harness.send(#"{"id":"3","type":"stopTurn","taskId":"A"}"#, on: phone)
        let awaited15 = try await phone.response("3").ok
        XCTAssertTrue(awaited15)
        await harness.send(#"{"id":"4","type":"markRead","taskId":"B"}"#, on: phone)
        let awaited16 = try await phone.response("4").ok
        XCTAssertTrue(awaited16)
        await harness.send(#"{"id":"5","type":"sendMessage","taskId":"A","text":"/clear"}"#, on: phone)
        let awaited17 = try await phone.response("5").error?.code
        XCTAssertEqual(awaited17, .unsupportedCommand)
        await harness.bridge.failNext(RemoteError(.notRunning))
        await harness.send(#"{"id":"6","type":"stopTurn","taskId":"B"}"#, on: phone)
        let awaited18 = try await phone.response("6").error?.code
        XCTAssertEqual(awaited18, .notRunning)

        let commands = await harness.bridge.commands
        XCTAssertEqual(commands, [
            .sendMessage(taskID: "A", text: "Secret plan: ship it"),
            .answerApproval(taskID: "A", requestID: "toolu_1", answer: .deny),
            .stopTurn(taskID: "A"),
            .markRead(taskID: "B"),
            .stopTurn(taskID: "B")
        ])
        let audit = harness.audit.entries().filter { $0.type != "pair" && $0.type != "hello" }
        XCTAssertEqual(audit.map(\.type), ["sendMessage", "answerApproval", "stopTurn", "markRead", "sendMessage", "stopTurn"])
        XCTAssertEqual(audit.map(\.result), ["ok", "ok", "ok", "ok", "unsupportedCommand", "notRunning"])
        XCTAssertEqual(audit.map(\.task), ["A", "A", "A", "B", "A", "B"])
        let log = try String(contentsOf: harness.auditURL, encoding: .utf8)
        XCTAssertFalse(log.contains("Secret"))
        XCTAssertFalse(log.contains("clear"))
    }

    func testCommandsAreRateLimited() async throws {
        let harness = try await ServerHarness()
        let phone = try await harness.authenticatedPhone()
        for index in 0..<11 {
            await harness.send(#"{"id":"\#(index)","type":"markRead","taskId":"A"}"#, on: phone)
        }
        let awaited19 = try await phone.response("9").ok
        XCTAssertTrue(awaited19)
        let awaited20 = try await phone.response("10").error?.code
        XCTAssertEqual(awaited20, .rateLimited)
    }

    func testRemovingADeviceDisconnectsIt() async throws {
        let harness = try await ServerHarness()
        let (device, token) = await harness.devices.add(name: "Pixel")
        let phone = await harness.connect()
        await harness.send(#"{"id":"1","type":"hello","protocolVersion":1,"token":"\#(token)"}"#, on: phone)
        let awaited21 = try await phone.response("1").ok
        XCTAssertTrue(awaited21)
        let connected = await harness.server.status.connectedDeviceIDs
        XCTAssertEqual(connected, [device.id])
        await harness.server.revoke(device.id)
        _ = try await phone.event(.revoked)
        try await phone.waitUntilClosed(.revoked)
        let again = await harness.connect()
        await harness.send(#"{"id":"1","type":"hello","protocolVersion":1,"token":"\#(token)"}"#, on: again)
        let awaited22 = try await again.response("1").error?.code
        XCTAssertEqual(awaited22, .invalidToken)
    }

    func testTurningTheRemoteOffClosesEveryConnection() async throws {
        let harness = try await ServerHarness()
        let phone = try await harness.authenticatedPhone()
        await harness.server.shutdown(reason: "disabled")
        let awaited23 = try await phone.event(.closing).reason
        XCTAssertEqual(awaited23, "disabled")
        try await phone.waitUntilClosed(.unavailable)
    }

    func testTooManyConnectionsAreTurnedAway() async throws {
        let harness = try await ServerHarness()
        for _ in 0..<8 { _ = await harness.connect() }
        let ninth = await harness.connect(expectingID: false)
        try await ninth.waitUntilClosed(.unavailable)
    }
}

// MARK: - Harness

/// A clock tests move by hand.
final class RemoteTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_792_158_000)

    var now: Date { lock.withLock { current } }
    func advance(by seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// A channel the test reads: every text the server sent, and how it closed.
final class TestChannel: RemoteChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    private var closeCode: RemoteCloseCode?
    var id: UUID?

    func send(_ text: String) { lock.withLock { texts.append(text) } }
    func close(_ code: RemoteCloseCode) { lock.withLock { if closeCode == nil { closeCode = code } } }

    var isClosed: Bool { lock.withLock { closeCode != nil } }

    func response(_ id: String, timeout: TimeInterval = testWaitLimitSeconds) async throws -> RemoteResponse {
        try await waitFor(timeout: timeout, "response \(id)") {
            self.decoded(RemoteResponse.self).first { $0.re == id }
        }
    }

    func event(_ name: RemoteEvent.Name, after seq: Int = 0,
               timeout: TimeInterval = testWaitLimitSeconds) async throws -> RemoteEvent {
        try await waitFor(timeout: timeout, "event \(name)") {
            self.decoded(RemoteEvent.self).first { $0.event == name && ($0.seq ?? 0) > seq }
        }
    }

    func waitUntilClosed(_ code: RemoteCloseCode, timeout: TimeInterval = testWaitLimitSeconds) async throws {
        let closed = try await waitFor(timeout: timeout, "close") { self.lock.withLock { self.closeCode } }
        XCTAssertEqual(closed, code)
    }

    private func decoded<Value: Decodable>(_ type: Value.Type) -> [Value] {
        lock.withLock { texts }.compactMap { try? JSONDecoder().decode(Value.self, from: Data($0.utf8)) }
    }

    private func waitFor<Value>(timeout: TimeInterval, _ what: String, _ read: () -> Value?) async throws -> Value {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = read() { return value }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TimedOut(description: "Timed out waiting for \(what): \(lock.withLock { texts })")
    }

    struct TimedOut: Error, CustomStringConvertible {
        let description: String
    }
}

actor FakeBridge: RemoteBridge {
    static let snapshot = RemoteSnapshot(
        projects: [RemoteProject(id: "P", name: "Yardlet", kind: .project)],
        tasks: [
            RemoteTask(id: "A", title: "Approve the migration", harness: "claude-code", harnessName: "Claude Code",
                       projectId: "P", attention: .active, indicator: .running, running: true, lastActivityAt: 2),
            RemoteTask(id: "B", title: "Fix the footer", harness: "codex", harnessName: "Codex",
                       projectId: "P", attention: .unread, indicator: .unread, unread: true, lastActivityAt: 1)
        ],
        newTask: RemoteNewTask(harness: "codex", harnessName: "Codex"))

    private var handler: (@Sendable (RemoteBridgeChange) -> Void)?
    private var current = FakeBridge.snapshot
    private var conversations: [String: RemoteConversation] = [:]
    private var earlier: [String: RemoteConversation] = [:]
    private var nextFailure: RemoteError?
    private(set) var commands: [RemoteCommand] = []
    private(set) var watchedTasks: Set<String> = []
    private(set) var preparedTasks: [String] = []
    private(set) var createdTasks: [(projectID: String, text: String)] = []
    private var details: [String: RemoteItemDetail] = [:]

    func setChangeHandler(_ handler: @escaping @Sendable (RemoteBridgeChange) -> Void) { self.handler = handler }
    func snapshot() -> RemoteSnapshot { current }
    func conversation(of taskID: String) -> RemoteConversation? { conversations[taskID] }
    func prepareConversation(of taskID: String) { preparedTasks.append(taskID) }
    func loadEarlierConversation(of taskID: String) {
        if let earlier = earlier.removeValue(forKey: taskID) { conversations[taskID] = earlier }
    }
    func setWatchedTasks(_ taskIDs: Set<String>) { watchedTasks = taskIDs }
    func perform(_ command: RemoteCommand) -> RemoteError? {
        commands.append(command)
        defer { nextFailure = nil }
        return nextFailure
    }

    func createTask(_ start: RemoteTaskStart) -> Result<String, RemoteError> {
        createdTasks.append((start.projectID, start.text))
        return .success("NEW-\(createdTasks.count)")
    }
    func itemDetail(taskID: String, itemID: String) -> Result<RemoteItemDetail, RemoteError> {
        details["\(taskID)/\(itemID)"].map { .success($0) } ?? .failure(RemoteError(.notFound))
    }

    func setDetail(_ detail: RemoteItemDetail, task: String, item: String) { details["\(task)/\(item)"] = detail }
    func setSnapshot(_ snapshot: RemoteSnapshot) { current = snapshot }
    func setConversation(_ conversation: RemoteConversation?, for taskID: String) { conversations[taskID] = conversation }
    func setEarlier(_ conversation: RemoteConversation, for taskID: String) { earlier[taskID] = conversation }
    func failNext(_ error: RemoteError) { nextFailure = error }
    func signal(_ change: RemoteBridgeChange) { handler?(change) }
}

struct ServerHarness {
    let server: RemoteServer
    let bridge = FakeBridge()
    let devices = RemoteDeviceStore(fileURL: nil)
    let audit: RemoteAuditLog
    let auditURL: URL

    init(clock: RemoteTestClock = RemoteTestClock()) async throws {
        auditURL = FileManager.default.temporaryDirectory.appending(path: "remote-server-\(UUID().uuidString)/audit.log")
        audit = RemoteAuditLog(fileURL: auditURL)
        var configuration = RemoteServer.Configuration(server: RemoteServerInfo(name: "Test Mac", appVersion: "test"))
        configuration.tasksInterval = .milliseconds(10)
        configuration.conversationInterval = .milliseconds(10)
        configuration.sweepInterval = .seconds(3600)
        configuration.olderWait = 2
        configuration.windowLimits = .init(maxTurns: 10)
        server = RemoteServer(configuration: configuration, bridge: bridge, devices: devices, audit: audit,
                              now: { clock.now })
        await server.start()
    }

    func connect(expectingID: Bool = true) async -> TestChannel {
        let channel = TestChannel()
        channel.id = await server.open(channel)
        if expectingID { XCTAssertNotNil(channel.id) }
        return channel
    }

    func send(_ text: String, on channel: TestChannel) async {
        guard let id = channel.id else { return }
        await server.receive(Data(text.utf8), on: id)
    }

    func authenticatedPhone() async throws -> TestChannel {
        let (_, token) = await devices.add(name: "Phone")
        let phone = await connect()
        await send(#"{"id":"hello","type":"hello","protocolVersion":1,"token":"\#(token)"}"#, on: phone)
        let awaited24 = try await phone.response("hello").ok
        XCTAssertTrue(awaited24)
        return phone
    }
}
