import Foundation
import XCTest
@testable import YardletRemote

/// The phone remote's wire contract (docs/REMOTE_PROTOCOL.md) without a connection: requests decode
/// and encode back the same, responses and events are the documented JSON, pairing codes and URLs
/// read back, the listen addresses are Tailscale's only (loopback only under the developer flag),
/// and a conversation window pages whole turns and describes updates as changes a client can apply.
final class RemoteProtocolTests: XCTestCase {
    // MARK: - Requests

    func testEveryRequestDecodesWhatItEncodes() throws {
        let requests: [RemoteRequest] = [
            .pair(code: "7KQ2M-X9D4T", deviceName: "Pixel 9", protocolVersion: 1),
            .hello(token: "q0Pj3w", protocolVersion: 1),
            .snapshot,
            .subscribeTask(taskID: "T1"),
            .loadOlder(taskID: "T1", cursor: "t:turn-3"),
            .unsubscribeTask(taskID: "T1"),
            .ping,
            .sendMessage(taskID: "T1", text: "Run the tests again"),
            .answerApproval(taskID: "T1", requestID: "toolu_1", answer: .allowOnce),
            .answerApproval(taskID: "T1", requestID: "toolu_1", answer: .deny),
            .stopTurn(taskID: "T1"),
            .markRead(taskID: "T1"),
            .answerQuestion(taskID: "T1", requestID: "q", answers: [RemoteQuestionAnswer(questionId: "a", options: ["Grid"]),
                                                                     RemoteQuestionAnswer(questionId: "b", skipped: true)]),
            .reviewPlan(taskID: "T1", requestID: "p", decision: .keepPlanning, reason: "Smaller steps"),
            .createTask(RemoteTaskStart(projectID: "P", text: "Add a toggle")),
            .createTask(RemoteTaskStart(projectID: "P", text: "", harness: "codex", settings: ["model": "gpt-6"], worktree: true,
                                        images: [RemoteImage(type: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]))])),
            .sendMessage(taskID: "T1", text: "Like this", images: [RemoteImage(type: "image/jpeg", data: Data([0xFF, 0xD8, 0xFF]))],
                         followUp: .queue),
            .answerApproval(taskID: "T1", requestID: "toolu_1", answer: .allowForSession),
            .answerApproval(taskID: "T1", requestID: "toolu_1", answer: .deny, note: "Run only the unit tests"),
            .newTaskOptions(projectID: "P", harness: nil),
            .newTaskOptions(projectID: "P", harness: "antigravity-cli", settings: ["model": "gemini-3-pro"]),
            .limitAccounts(taskID: "T1"),
            .continueWithAccount(taskID: "T1", accountID: "conn-2"),
            .setAutoContinue(taskID: "T1", enabled: true),
            .actOnQueued(taskID: "T1", itemID: "queued:1", action: .stopAndSend),
            .answerHandoff(taskID: "T1", requestID: "h", answer: .decline),
            .chooseAnswer(taskID: "T1", requestID: "r", choice: "1"),
            .chooseAnswer(taskID: "T1", requestID: "r", choice: "0", note: "Not now",
                          values: ["repo": .text("acme/web"), "private": .flag(true), "count": .number(3), "teams": .list(["web"])]),
            .uploadFile(RemoteUploadPart(uploadID: "6F9619FF-8B86-D011-B42D-00C04FC964FF", name: "a.pdf", mediaType: "application/pdf",
                                         size: 3, offset: 0, data: Data([1, 2, 3]))),
            .sendMessage(taskID: "T1", text: "", files: ["6F9619FF-8B86-D011-B42D-00C04FC964FF"]),
            .registerPush(provider: "fcm", token: "t"),
            .unregisterPush,
            .forgetDevice,
            .itemDetail(taskID: "T1", itemID: "i:1"),
            .actOnSuggestion(taskID: "T1", suggestionID: "task_1", action: .start),
            .setPinned(taskID: "T1", pinned: false),
            .archiveTask(taskID: "T1"),
            .answerLink(requestID: "L", approve: true)
        ]
        for (index, request) in requests.enumerated() {
            let envelope = RemoteRequestEnvelope(id: "\(index)", request: request)
            XCTAssertEqual(try RemoteRequestEnvelope.decode(envelope.encoded()).get(), envelope, "\(request)")
        }
    }

    func testTheDocumentedRequestsDecode() throws {
        let markRead = try decode(#"{"id": "17", "type": "markRead", "taskId": "4C1F"}"#)
        XCTAssertEqual(markRead, RemoteRequestEnvelope(id: "17", request: .markRead(taskID: "4C1F")))
        let answer = try decode(#"{"id":"8","type":"answerApproval","taskId":"T","requestId":"toolu_01","answer":"allowOnce","extra":true}"#)
        XCTAssertEqual(answer.request, .answerApproval(taskID: "T", requestID: "toolu_01", answer: .allowOnce))
        let pair = try decode(#"{"id":"1","type":"pair","protocolVersion":1,"code":"7KQ2M-X9D4T","deviceName":"  Pixel 9  "}"#)
        XCTAssertEqual(pair.request, .pair(code: "7KQ2M-X9D4T", deviceName: "Pixel 9", protocolVersion: 1))
    }

    func testRequestsThatCannotBeReadSayWhy() {
        func failure(_ json: String) -> RemoteRequestEnvelope.DecodingFailure? {
            guard case let .failure(failure) = RemoteRequestEnvelope.decode(Data(json.utf8)) else { return nil }
            return failure
        }
        XCTAssertEqual(failure("[1, 2]")?.error.code, .badRequest)
        XCTAssertEqual(failure("not json")?.error.code, .badRequest)
        XCTAssertEqual(failure(#"{"type":"snapshot"}"#)?.error.code, .badRequest)
        XCTAssertEqual(failure(#"{"id":"3","type":"launchMissiles"}"#), .init(id: "3", error: RemoteError(.unknownType, "Unknown type launchMissiles")))
        XCTAssertEqual(failure(#"{"id":"4","type":"markRead"}"#)?.error.code, .badRequest)
        XCTAssertEqual(failure(#"{"id":"5","type":"answerApproval","taskId":"T","requestId":"r","answer":"allowAlways"}"#)?.error.code, .badRequest)
        XCTAssertEqual(failure(#"{"id":6,"type":"ping"}"#)?.error.code, .badRequest)
        XCTAssertEqual(failure(#"{"id":"7","type":"hello","token":"x"}"#)?.id, "7")
    }

    // MARK: - Responses and events

    func testResponsesAndEventsAreTheDocumentedJSON() throws {
        XCTAssertEqual(RemoteJSON.string(RemoteResponse(re: "17")), #"{"ok":true,"re":"17"}"#)
        XCTAssertEqual(RemoteJSON.string(RemoteResponse.failure("18", RemoteError(.notFound, "No task"))),
                       #"{"error":{"code":"notFound","message":"No task"},"ok":false,"re":"18"}"#)
        var event = RemoteEvent(.conversation)
        event.seq = 5
        event.taskId = "T"
        var item = RemoteItem(id: "i:91AA", turnId: "3F2A", kind: .assistant)
        item.role = "answer"
        item.text = "All **12** tests pass."
        item.streaming = true
        event.changes = [.remove("req:toolu_01"), .upsert(item, after: "i:5D0C")]
        XCTAssertEqual(RemoteJSON.string(event), #"{"changes":[{"id":"req:toolu_01","op":"remove"},{"after":"i:5D0C","item":{"id":"i:91AA","kind":"assistant","role":"answer","streaming":true,"text":"All **12** tests pass.","turnId":"3F2A"},"op":"upsert"}],"event":"conversation","seq":5,"taskId":"T"}"#)

        let task = RemoteTask(id: "T", title: "Approve", harness: "claude-code", harnessName: "Claude Code", projectId: "P",
                              attention: .waiting, indicator: .awaitingApproval, pendingRequest: .approval,
                              running: true, lastActivityAt: 1_792_158_000_000, parentTaskId: "Q")
        var snapshot = RemoteResponse(re: "2")
        snapshot.projects = [RemoteProject(id: "chats", name: "Chats", kind: .chats)]
        snapshot.tasks = [task]
        let data = try RemoteJSON.encoder.encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(RemoteResponse.self, from: data), snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let first = try XCTUnwrap((object["tasks"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["attention"] as? String, "waiting")
        XCTAssertEqual(first["indicator"] as? String, "awaitingApproval")
        XCTAssertEqual(first["lastActivityAt"] as? Int64, 1_792_158_000_000)
        XCTAssertEqual(first["unread"] as? Bool, false)
    }

    func testEveryErrorCodeIsDocumented() throws {
        let document = try String(contentsOf: Self.protocolDocument, encoding: .utf8)
        for code in RemoteErrorCode.allCases {
            XCTAssertTrue(document.contains("| `\(code.rawValue)` |"), "\(code.rawValue) is missing from the error table")
        }
        for name in ["tasksChanged", "attention", "conversation", "conversationReset", "conversationEnded", "revoked", "closing",
                     "linked", "linkRefused", "linkRequest", "linkResolved"] {
            XCTAssertTrue(document.contains("\"event\": \"\(name)\""), name)
        }
        XCTAssertTrue(document.contains("**Port: `\(RemoteProtocol.defaultPort)`**"))
        XCTAssertTrue(document.contains("port **\(RemoteProtocol.securePort)**"))
        XCTAssertTrue(document.contains("prologue the 16 ASCII bytes `\(String(decoding: RemoteNoise.prologue, as: UTF8.self))`"))
    }

    // MARK: - Pairing

    func testPairingCodesReadAsTypedAndCompareWhole() {
        let code = RemotePairingCode.generate()
        XCTAssertEqual(code.count, 10)
        XCTAssertTrue(code.allSatisfy { RemotePairingCode.alphabet.contains($0) })
        XCTAssertNotEqual(code, RemotePairingCode.generate())
        XCTAssertEqual(RemotePairingCode.display("7KQ2MX9D4T"), "7KQ2M-X9D4T")
        XCTAssertEqual(RemotePairingCode.normalize("7kq2m-x9d4t"), "7KQ2MX9D4T")
        XCTAssertEqual(RemotePairingCode.normalize("ABCDE 12345"), "ABCDE12345")
        XCTAssertEqual(RemotePairingCode.normalize("o1l1i"), "01111")
        XCTAssertNil(RemotePairingCode.normalize("ABCDU-12345"))
        XCTAssertTrue(RemotePairingCode.matches("7kq2m x9d4t", "7KQ2MX9D4T"))
        XCTAssertFalse(RemotePairingCode.matches("7KQ2M-X9D4", "7KQ2MX9D4T"))
        XCTAssertFalse(RemotePairingCode.matches("7KQ2M-X9D4V", "7KQ2MX9D4T"))
    }

    func testDeviceTokensAreRandomAndStoredOnlyAsDigests() async throws {
        let token = RemoteDeviceToken.generate()
        XCTAssertEqual(token.count, 43)
        XCTAssertFalse(token.contains("=") || token.contains("+") || token.contains("/"))
        XCTAssertEqual(RemoteDeviceToken.hash(token).count, 64)

        let folder = FileManager.default.temporaryDirectory.appending(path: "remote-devices-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "devices.json")
        let store = RemoteDeviceStore(fileURL: file)
        let (device, issued) = await store.add(name: "Pixel 9")
        let saved = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(saved.contains(issued))
        XCTAssertTrue(saved.contains(RemoteDeviceToken.hash(issued)))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)

        let reopened = RemoteDeviceStore(fileURL: file)
        let authenticated = await reopened.authenticate(issued)
        XCTAssertEqual(authenticated?.id, device.id)
        let stranger = await reopened.authenticate(RemoteDeviceToken.generate())
        XCTAssertNil(stranger)
        await reopened.remove(device.id)
        let removed = await reopened.authenticate(issued)
        XCTAssertNil(removed)
    }

    func testThePairingURLNamesItsHostsInOrder() throws {
        let url = try XCTUnwrap(RemotePairingURL.make(code: "7KQ2MX9D4T",
            hosts: ["100.64.12.34", "mac.tail1234.ts.net", "fd7a:115c:a1e0::1234"], port: 47615, macName: "MacBook Pro"))
        XCTAssertTrue(url.absoluteString.hasPrefix("yardlet-remote://pair?v=1&code=7KQ2M-X9D4T&port=47615&host=100.64.12.34"))
        let parsed = try XCTUnwrap(RemotePairingURL.parse(url))
        XCTAssertEqual(parsed, .init(version: 1, code: "7KQ2M-X9D4T", port: 47615,
            hosts: ["100.64.12.34", "mac.tail1234.ts.net", "fd7a:115c:a1e0::1234"], name: "MacBook Pro"))
    }

    // MARK: - Addresses

    func testTheRemoteListensOnTailscaleAddressesOnly() {
        let interfaces = [
            RemoteInterfaceAddress(interface: "lo0", address: "127.0.0.1", family: .ipv4),
            RemoteInterfaceAddress(interface: "lo0", address: "::1", family: .ipv6),
            RemoteInterfaceAddress(interface: "en0", address: "192.168.0.12", family: .ipv4),
            RemoteInterfaceAddress(interface: "en0", address: "fe80::1c2b:3a4d:5e6f:7081%en0", family: .ipv6),
            RemoteInterfaceAddress(interface: "en0", address: "10.0.0.4", family: .ipv4),
            RemoteInterfaceAddress(interface: "utun4", address: "fd7a:115c:a1e0::1234", family: .ipv6),
            RemoteInterfaceAddress(interface: "utun4", address: "100.64.12.34", family: .ipv4),
            // Outside Tailscale's ranges: CGNAT's neighbours, another ULA.
            RemoteInterfaceAddress(interface: "utun5", address: "100.128.0.1", family: .ipv4),
            RemoteInterfaceAddress(interface: "utun5", address: "100.63.255.255", family: .ipv4),
            RemoteInterfaceAddress(interface: "utun6", address: "fd7a:115c:a1e1::1", family: .ipv6),
            RemoteInterfaceAddress(interface: "bridge0", address: "0.0.0.0", family: .ipv4)
        ]
        XCTAssertEqual(RemoteAddressSelection.listenAddresses(among: interfaces, loopback: false), [
            RemoteListenAddress(host: "100.64.12.34", family: .ipv4, kind: .tailscale),
            RemoteListenAddress(host: "fd7a:115c:a1e0::1234", family: .ipv6, kind: .tailscale)
        ])
        XCTAssertEqual(RemoteAddressSelection.listenAddresses(among: interfaces, loopback: true).last,
                       RemoteListenAddress(host: "127.0.0.1", family: .ipv4, kind: .loopback))
        XCTAssertEqual(RemoteAddressSelection.listenAddresses(among: [], loopback: false), [])
        XCTAssertTrue(RemoteAddressSelection.isTailscale("100.64.0.0"))
        XCTAssertTrue(RemoteAddressSelection.isTailscale("100.127.255.255"))
        XCTAssertFalse(RemoteAddressSelection.isTailscale("100.100.100.100.1"))
        XCTAssertEqual(RemoteListenAddress(host: "fd7a:115c:a1e0::1", family: .ipv6, kind: .tailscale).urlHost, "[fd7a:115c:a1e0::1]")
    }

    func testTheDeveloperLoopbackNeedsItsFlag() throws {
        let suite = testDefaultsSuite("remote-loopback")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertFalse(RemoteAddressSelection.loopbackEnabled(environment: [:], defaults: defaults))
        XCTAssertTrue(RemoteAddressSelection.loopbackEnabled(environment: ["YARDLET_REMOTE_LOOPBACK": "1"], defaults: defaults))
        XCTAssertFalse(RemoteAddressSelection.loopbackEnabled(environment: ["YARDLET_REMOTE_LOOPBACK": "0"], defaults: defaults))
        defaults.set(true, forKey: RemoteAddressSelection.loopbackDefaultsKey)
        XCTAssertTrue(RemoteAddressSelection.loopbackEnabled(environment: [:], defaults: defaults))
    }

    func testTheSystemInterfacesIncludeLoopback() {
        // Reads only; nothing binds.
        XCTAssertTrue(RemoteAddressSelection.systemInterfaces().contains { $0.address == "127.0.0.1" })
    }

    // MARK: - Messages and limits

    func testAFilesNameKeepsNoPathAndNoHiddenStart() {
        XCTAssertEqual(RemoteUploadStore.safeName("../../etc/passwd"), "passwd")
        XCTAssertEqual(RemoteUploadStore.safeName("C:\\Users\\me\\..\\report.pdf"), "report.pdf")
        XCTAssertEqual(RemoteUploadStore.safeName(".zshrc"), "zshrc")
        XCTAssertEqual(RemoteUploadStore.safeName("a:b\u{0007}.txt"), "ab.txt")
        XCTAssertEqual(RemoteUploadStore.safeName("..."), "file")
        let long = RemoteUploadStore.safeName(String(repeating: "x", count: 200) + ".pdf")
        XCTAssertEqual(long.count, 120)
        XCTAssertTrue(long.hasSuffix(".pdf"))
        let combining = RemoteUploadStore.safeName("e" + String(repeating: "\u{0301}", count: 1_000) + ".txt")
        XCTAssertLessThanOrEqual(combining.utf8.count, 200, "A file system name holds 255 bytes")
        XCTAssertTrue(combining.hasSuffix(".txt"))
    }

    func testAnUploadIDIsNeverReusedAndWhatNoMessageTookGoesAtTheNextStart() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "remote-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var store = RemoteUploadStore(directory: directory)
        let now = Date()
        let taken = UUID().uuidString, left = UUID().uuidString
        for id in [taken, left] {
            XCTAssertEqual(try store.receive(RemoteUploadPart(uploadID: id, name: "a.txt", size: 2, offset: 0, data: Data("hi".utf8)),
                                             from: "phone", now: now).get(), 2)
        }
        let file = try store.files([taken], from: "phone").get()[0]
        XCTAssertEqual(store.files([taken], from: "other").map { _ in true }, .failure(RemoteError(.notFound, "An upload is not finished or has expired")))
        store.release([taken])
        // The same ID again, from any device, is refused and leaves the taken file alone.
        let reuse = store.receive(RemoteUploadPart(uploadID: taken, name: "a.txt", size: 2, offset: 0, data: Data("no".utf8)),
                                  from: "other", now: now)
        XCTAssertEqual((try? reuse.get()), nil)
        XCTAssertEqual(try String(contentsOf: file.url, encoding: .utf8), "hi")
        // A new run keeps what a message took and removes the rest.
        _ = RemoteUploadStore(directory: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: left).path))
    }

    func testMessagesTheMacWouldNotSendAreRefused() {
        XCTAssertEqual(RemoteServer.validateMessage("   ")?.code, .emptyMessage)
        XCTAssertEqual(RemoteServer.validateMessage(String(repeating: "a", count: 32_001))?.code, .tooLarge)
        XCTAssertEqual(RemoteServer.validateMessage("/clear")?.code, .unsupportedCommand)
        XCTAssertEqual(RemoteServer.validateMessage("  /model gpt-5 ")?.code, .unsupportedCommand)
        XCTAssertEqual(RemoteServer.validateMessage("/review:pr 12")?.code, .unsupportedCommand)
        XCTAssertNil(RemoteServer.validateMessage("/Users/me/project/README.md is outdated"))
        XCTAssertNil(RemoteServer.validateMessage("Run the tests again"))
        XCTAssertNil(RemoteServer.validateMessage("/ alone"))
    }

    func testRatesRefillAndCommandsHaveTheirOwnBucket() {
        let start = Date(timeIntervalSince1970: 0)
        var limiter = RemoteRateLimiter(now: start)
        for _ in 0..<10 { XCTAssertTrue(limiter.admit(isCommand: true, now: start)) }
        XCTAssertFalse(limiter.admit(isCommand: true, now: start))
        XCTAssertTrue(limiter.admit(isCommand: false, now: start))
        XCTAssertTrue(limiter.admit(isCommand: true, now: start.addingTimeInterval(3.1)))
        var reads = RemoteRateLimiter(now: start)
        for _ in 0..<30 { XCTAssertTrue(reads.admit(isCommand: false, now: start)) }
        XCTAssertFalse(reads.admit(isCommand: false, now: start))
        XCTAssertEqual(reads.refusedInARow, 1)
        XCTAssertTrue(reads.admit(isCommand: false, now: start.addingTimeInterval(0.2)))
        XCTAssertEqual(reads.refusedInARow, 0)
    }

    func testTheAuditLogKeepsTypesAndTasksAndTrims() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "remote-audit-\(UUID().uuidString)/audit.log")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let log = RemoteAuditLog(fileURL: file, keptLines: 8)
        for index in 0..<30 { log.record(device: "D", type: "markRead", task: "T\(index)", result: "ok") }
        let entries = log.entries()
        XCTAssertLessThanOrEqual(entries.count, 10)
        XCTAssertEqual(entries.last?.task, "T29")
        XCTAssertEqual(entries.last?.type, "markRead")
    }

    // MARK: - Summaries

    func testASummaryIsOneShortLineWithSecretsMasked() {
        XCTAssertEqual(RemoteSummary.line(["Bash", "Run the migration tests"]), "Bash: Run the migration tests")
        XCTAssertEqual(RemoteSummary.line(["Question", nil, "Which layout?\nGrid or list"]), "Question: Which layout?")
        XCTAssertEqual(RemoteSummary.line(["Bash", "Bash"]), "Bash")
        XCTAssertNil(RemoteSummary.line([nil, "  "]))
        let long = RemoteSummary.line(["Bash", String(repeating: "echo hello ", count: 40)])
        XCTAssertEqual(long?.count, RemoteSummary.limit)
        XCTAssertEqual(long?.last, "…")

        let masked = RemoteSummary.line(["Bash", #"curl -H "Authorization: Bearer sk-live-4f9a8b7c6d5e" https://deploy:hunter2@example.test/api"#])
        XCTAssertNotNil(masked)
        XCTAssertFalse(masked!.contains("sk-live-4f9a8b7c6d5e"), masked!)
        XCTAssertFalse(masked!.contains("hunter2"), masked!)
        let assignments = RemoteSummary.masked("export GITHUB_TOKEN=ghp_abc123 API_KEY: \"s3cr3t\" --password hunter2 ls")
        XCTAssertFalse(assignments.contains("ghp_abc123") || assignments.contains("s3cr3t") || assignments.contains("hunter2"), assignments)
        XCTAssertTrue(assignments.hasSuffix("ls"))
        XCTAssertEqual(RemoteSummary.masked("key 9f8e7d6c5b4a39281706f5e4d3c2b1a0ffeeddcc"), "key •••")
        XCTAssertEqual(RemoteSummary.masked("swift test --filter RemoteServerTests"), "swift test --filter RemoteServerTests")
        XCTAssertEqual(RemoteSummary.masked("cat /Users/me/project2/Sources/Remote/RemoteServer.swift"),
                       "cat /Users/me/project2/Sources/Remote/RemoteServer.swift")
    }

    // MARK: - Conversation window

    func testAPageIsWholeTurnsFromTheLatestAndOlderPagesComeBefore() {
        let conversation = RemoteConversation(turns: (1...25).map { Self.turn("t\($0)", items: 3) })
        var window = RemoteConversationWindow(limits: .init(maxTurns: 10, maxItems: 1_000))
        let page = window.open(conversation)
        XCTAssertEqual(Set(page.items.map(\.turnId)).count, 10)
        XCTAssertEqual(page.items.first?.turnId, "t16")
        XCTAssertEqual(page.items.last?.turnId, "t25")
        XCTAssertEqual(page.cursor, "t:t16")
        XCTAssertTrue(page.hasOlder)

        guard case let .page(older) = window.older("t:t16", in: conversation) else { return XCTFail() }
        XCTAssertEqual(older.items.first?.turnId, "t6")
        XCTAssertEqual(older.items.last?.turnId, "t15")
        guard case let .page(oldest) = window.older("t:t6", in: conversation) else { return XCTFail() }
        XCTAssertEqual(oldest.items.first?.turnId, "t1")
        XCTAssertFalse(oldest.hasOlder)
        XCTAssertNil(oldest.cursor)
        XCTAssertEqual(window.older("t:t16", in: conversation), .invalidCursor)
        XCTAssertEqual(window.sent.count, 75)
    }

    func testAPageStopsAtItsItemLimitButKeepsOneTurnWhole() {
        let conversation = RemoteConversation(turns: [Self.turn("a", items: 5), Self.turn("b", items: 300)], hasEarlier: true)
        var window = RemoteConversationWindow(limits: .init(maxTurns: 10, maxItems: 120))
        let page = window.open(conversation)
        XCTAssertEqual(page.items.count, 300)
        XCTAssertEqual(page.cursor, "t:b")
        guard case let .page(older) = window.older("t:b", in: conversation) else { return XCTFail() }
        XCTAssertEqual(older.items.count, 5)
        XCTAssertTrue(older.hasOlder)
        XCTAssertEqual(window.older("t:a", in: conversation), .needsProvider)
    }

    func testUpdatesAreChangesThatReproduceTheConversation() throws {
        var turns = (1...4).map { Self.turn("t\($0)", items: 3) }
        var window = RemoteConversationWindow()
        var client = window.open(RemoteConversation(turns: turns)).items

        // Streaming: an item changes in place, a new one arrives, a request moves into the work.
        turns[3].items[1].text = "streamed further"
        var answer = RemoteItem(id: "i:t4-answer", turnId: "t4", kind: .assistant)
        answer.text = "Done"
        turns[3].items.append(answer)
        let moved = turns[3].items.remove(at: 2)
        turns[3].items.insert(moved, at: 0)
        turns.append(Self.turn("t5", items: 2))
        guard case let .changes(changes) = window.update(RemoteConversation(turns: turns)) else { return XCTFail() }
        client = Self.strictlyApplying(changes, to: client)
        XCTAssertEqual(client, turns.flatMap(\.items))
        XCTAssertTrue(changes.contains { $0.op == .upsert && $0.item?.id == "i:t4-1" && $0.after == "i:t4-0" })

        XCTAssertEqual(window.update(RemoteConversation(turns: turns)), .unchanged)

        // An item goes away.
        turns[1].items.remove(at: 1)
        guard case let .changes(removal) = window.update(RemoteConversation(turns: turns)) else { return XCTFail() }
        XCTAssertEqual(removal, [.remove("i:t2-1")])
        client = client.applying(removal)
        XCTAssertEqual(client, turns.flatMap(\.items))
    }

    func testAWindowWhoseStartIsGoneIsSentAgainWhole() {
        let turns = (1...3).map { Self.turn("t\($0)", items: 2) }
        var window = RemoteConversationWindow()
        _ = window.open(RemoteConversation(turns: turns))
        let reread = (1...3).map { Self.turn("r\($0)", items: 2) }
        guard case let .reset(page) = window.update(RemoteConversation(turns: reread)) else { return XCTFail() }
        XCTAssertEqual(page.items, reread.flatMap(\.items))
    }

    func testTheLongestRunInOrderStaysPut() {
        XCTAssertEqual(RemoteConversationWindow.longestIncreasingRun([3, 0, 1, 4, 2, 5]), [0, 1, 2, 5])
        XCTAssertEqual(RemoteConversationWindow.longestIncreasingRun([]), [])
        XCTAssertNil(RemoteConversationWindow.changes(from: [Self.item("a"), Self.item("a")], to: []))
    }

    // MARK: - Helpers

    static func turn(_ id: String, items count: Int) -> RemoteTurn {
        RemoteTurn(id: id, items: (0..<count).map { index in
            var item = RemoteItem(id: "i:\(id)-\(index)", turnId: id, kind: index == 0 ? .user : .activity)
            item.text = "\(id) item \(index)"
            return item
        })
    }

    static func item(_ id: String) -> RemoteItem { RemoteItem(id: id, turnId: "t", kind: .notice) }

    /// The changes applied as §5.3 says, failing when an `upsert` names an `after` the client does
    /// not hold: the server must never send one.
    static func strictlyApplying(_ changes: [RemoteChange], to items: [RemoteItem],
                                 file: StaticString = #filePath, line: UInt = #line) -> [RemoteItem] {
        var items = items
        for change in changes {
            // An item new to the client goes after one it holds once the changes before are applied.
            if change.op == .upsert, let item = change.item, !items.contains(where: { $0.id == item.id }),
               let after = change.after {
                XCTAssertTrue(items.contains { $0.id == after },
                              "after \(after) names an item the client does not hold", file: file, line: line)
            }
            items = items.applying([change])
        }
        return items
    }

    static let protocolDocument = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "docs/REMOTE_PROTOCOL.md")

    private func decode(_ json: String) throws -> RemoteRequestEnvelope {
        try RemoteRequestEnvelope.decode(Data(json.utf8)).get()
    }
}
