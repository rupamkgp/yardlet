import Foundation
import XCTest
@testable import YardletRemote

/// The remote end to end on loopback: a real `NWListener` WebSocket bound to 127.0.0.1 on a free
/// port, the fixture bridge behind it, and `URLSessionWebSocketTask` as the phone. Nothing listens on
/// any other address, and no provider runs.
final class RemoteEndToEndTests: XCTestCase {
    func testAPhonePairsFollowsATaskAndAnswersItsApproval() async throws {
        let stack = try await LoopbackStack()
        defer { stack.stop() }
        let ticket = await stack.server.openPairing()
        let phone = stack.socket()
        defer { phone.close() }

        try await phone.send(#"{"id":"1","type":"pair","protocolVersion":1,"code":"\#(ticket.displayCode)","deviceName":"Emulator"}"#)
        let paired = try await phone.response("1")
        XCTAssertTrue(paired.ok, "\(paired)")
        XCTAssertEqual(paired.token?.count, 43)

        try await phone.send(#"{"id":"2","type":"snapshot"}"#)
        let snapshot = try await phone.response("2")
        let approval = try XCTUnwrap(snapshot.tasks?.first { $0.id == RemoteFixtureBridge.ID.approval })
        XCTAssertEqual(approval.attention, .waiting)
        XCTAssertEqual(approval.indicator, .awaitingApproval)
        XCTAssertEqual(snapshot.projects?.map(\.kind), [.project, .project, .chats])
        XCTAssertEqual(snapshot.tasks?.first { $0.id == RemoteFixtureBridge.ID.child }?.parentTaskId, RemoteFixtureBridge.ID.idle)

        try await phone.send(#"{"id":"3","type":"subscribeTask","taskId":"\#(RemoteFixtureBridge.ID.approval)"}"#)
        let subscribed = try await phone.response("3")
        var items = try XCTUnwrap(subscribed.items)
        let request = try XCTUnwrap(items.first { $0.kind == .approval && $0.status == "pending" })
        XCTAssertEqual(request.options, ["allowOnce", "deny"])
        XCTAssertEqual(request.moreOnMac, true)

        try await phone.send(#"{"id":"4","type":"answerApproval","taskId":"\#(RemoteFixtureBridge.ID.approval)","requestId":"\#(request.requestId ?? "")","answer":"allowOnce"}"#)
        let awaited25 = try await phone.response("4").ok
        XCTAssertTrue(awaited25)

        // The command runs and the answer streams in as changes, until the turn completes.
        let finished = try await phone.waitFor("the finished answer") { () -> [RemoteItem]? in
            for event in phone.takeEvents(.conversation) { items = items.applying(event.changes ?? []) }
            let answer = items.last { $0.kind == .assistant && $0.role == "answer" }
            return answer?.streaming == nil && answer?.text?.contains("migration tests pass") == true ? items : nil
        }
        XCTAssertEqual(finished.first { $0.id == request.id }?.status, "allowed")
        XCTAssertEqual(finished.first { $0.kind == .activity && $0.activity == "command" }?.exitCode, 0)
        let attention = try await phone.waitFor("attention") {
            phone.events(.attention).first { $0.taskId == RemoteFixtureBridge.ID.approval && $0.state == .unread }
        }
        // Snapshots are coalesced: a fast turn can go from waiting to unread between two of them.
        XCTAssertTrue([.active, .waiting].contains(attention.previousState), "\(attention)")

        // A second connection authenticates with the token alone.
        let again = stack.socket()
        defer { again.close() }
        try await again.send(#"{"id":"1","type":"hello","protocolVersion":1,"token":"\#(paired.token ?? "")"}"#)
        let awaited26 = try await again.response("1").deviceId
        XCTAssertEqual(awaited26, paired.deviceId)
        try await again.send(#"{"id":"2","type":"stopTurn","taskId":"\#(RemoteFixtureBridge.ID.idle)"}"#)
        let awaited27 = try await again.response("2").error?.code
        XCTAssertEqual(awaited27, .notRunning)
    }

    func testABrowserHandshakeIsRefused() async throws {
        let stack = try await LoopbackStack()
        defer { stack.stop() }
        let started = Date()
        let browser = stack.socket(origin: "https://example.test")
        defer { browser.close() }
        do {
            try await browser.send(#"{"id":"1","type":"ping"}"#)
            _ = try await browser.task.receive()
            XCTFail("A handshake with Origin was accepted")
        } catch {
            // Refused before any frame, and the socket let go at once.
            XCTAssertEqual((browser.task.response as? HTTPURLResponse)?.statusCode, 400)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        let status = await stack.server.status
        XCTAssertTrue(status.connectedDeviceIDs.isEmpty)
    }

    func testOversizedAndBinaryFramesCloseTheConnection() async throws {
        let stack = try await LoopbackStack()
        defer { stack.stop() }
        let big = stack.socket()
        defer { big.close() }
        try? await big.send(String(repeating: "x", count: RemoteProtocol.maxClientFrameBytes + 10))
        try await big.waitUntilClosed()

        let binary = stack.socket()
        defer { binary.close() }
        try? await binary.task.send(.data(Data([1, 2, 3])))
        try await binary.waitUntilClosed()
        let closed = await stack.server.status.connectedDeviceIDs
        XCTAssertTrue(closed.isEmpty)
    }
}

/// A server on 127.0.0.1 with the fixture tasks, run fast.
final class LoopbackStack: @unchecked Sendable {
    let server: RemoteServer
    let listeners: RemoteWebSocketListeners
    let port: UInt16

    init() async throws {
        server = RemoteServer(
            configuration: RemoteServer.Configuration(server: RemoteServerInfo(name: "Loopback", appVersion: "test")),
            bridge: RemoteFixtureBridge(speed: 25), devices: RemoteDeviceStore(fileURL: nil))
        await server.start()
        listeners = RemoteWebSocketListeners(server: server, port: 0)
        let address = RemoteListenAddress(host: "127.0.0.1", family: .ipv4, kind: .loopback)
        listeners.listen(on: [address])
        let deadline = Date().addingTimeInterval(5)
        var bound: UInt16?
        while bound == nil, Date() < deadline {
            if case let .ready(port)? = listeners.currentStates[address], port != 0 { bound = port }
            try await Task.sleep(for: .milliseconds(10))
        }
        port = try XCTUnwrap(bound, "The loopback listener did not start: \(listeners.currentStates)")
        XCTAssertEqual(listeners.currentStates.keys.map(\.host), ["127.0.0.1"])
    }

    func socket(origin: String? = nil) -> PhoneSocket {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/")!)
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        return PhoneSocket(task: URLSession.shared.webSocketTask(with: request))
    }

    func stop() {
        listeners.stop()
    }
}

/// `URLSessionWebSocketTask` as a phone: every frame it receives, read as responses and events.
final class PhoneSocket: @unchecked Sendable {
    let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var texts: [String] = []
    private var consumed: [RemoteEvent.Name: Int] = [:]
    private var ended = false

    init(task: URLSessionWebSocketTask) {
        self.task = task
        task.maximumMessageSize = 8 << 20
        task.resume()
        receive()
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(.string(text)):
                lock.withLock { texts.append(text) }
                receive()
            case .success:
                receive()
            case .failure:
                lock.withLock { ended = true }
            }
        }
    }

    func send(_ text: String) async throws { try await task.send(.string(text)) }

    func close() { task.cancel(with: .normalClosure, reason: nil) }

    func response(_ id: String) async throws -> RemoteResponse {
        try await waitFor("response \(id)") {
            self.lock.withLock { self.texts }.lazy
                .compactMap { try? JSONDecoder().decode(RemoteResponse.self, from: Data($0.utf8)) }
                .first { $0.re == id }
        }
    }

    /// The events of a name not yet taken, in order.
    func events(_ name: RemoteEvent.Name) -> [RemoteEvent] {
        let (received, taken) = lock.withLock { (texts, consumed[name, default: 0]) }
        return Array(Self.events(name, in: received).dropFirst(taken))
    }

    /// The events of a name not yet taken, in order, marked taken in the same read: one that arrives meanwhile
    /// is left for the next call rather than marked taken unseen.
    func takeEvents(_ name: RemoteEvent.Name) -> [RemoteEvent] {
        let (received, taken) = lock.withLock { (texts, consumed[name, default: 0]) }
        let all = Self.events(name, in: received)
        lock.withLock { consumed[name] = all.count }
        return Array(all.dropFirst(taken))
    }

    private static func events(_ name: RemoteEvent.Name, in texts: [String]) -> [RemoteEvent] {
        texts.compactMap { try? JSONDecoder().decode(RemoteEvent.self, from: Data($0.utf8)) }.filter { $0.event == name }
    }

    func waitUntilClosed() async throws {
        _ = try await waitFor("close") { self.lock.withLock { self.ended } ? true : nil }
    }

    func waitFor<Value>(_ what: String, timeout: TimeInterval = 10, _ read: () -> Value?) async throws -> Value {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = read() { return value }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestChannel.TimedOut(description: "Timed out waiting for \(what): \(lock.withLock { texts.suffix(5) })")
    }
}
