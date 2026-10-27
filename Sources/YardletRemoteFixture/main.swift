import CryptoKit
import Foundation
import YardletRemote

// yardlet-remote-fixture: the phone remote's protocol on loopback, with fixture tasks instead of the
// Mac's real ones (docs/REMOTE_PROTOCOL.md §9). It binds 127.0.0.1 only; the Android emulator reaches
// it as 10.0.2.2. Its paired devices are kept in memory, its audit log in a temporary folder.
//
//   swift run --build-system native yardlet-remote-fixture [--port 47615] [--single-use-pairing]
//       [--v2] [--secure-port 47616] [--host 10.0.2.2:47616]… [--relay ws://127.0.0.1:8787]
//       [--relay-public ws://10.0.2.2:8787] [--approve-links]
//
// With --v2 it also serves protocol v2 (§11–§17) on 127.0.0.1 with a fixed fixture Mac key, and prints
// the v2 pairing URL (its secret is fixed and reusable unless --single-use-pairing). --relay opens the
// fixture's room on a local relay (`relay/`, `wrangler dev`); --relay-public is the address phones are
// told for it. --approve-links approves a link request (§12.1) three seconds after it arrives.

// Each line shows at once, also when the output goes to a pipe or a file.
setvbuf(stdout, nil, _IOLBF, 0)
let arguments = CommandLine.arguments.dropFirst()
func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.index(after: index) < arguments.endIndex else { return nil }
    return arguments[arguments.index(after: index)]
}
if arguments.contains("--help") || arguments.contains("-h") {
    print("usage: yardlet-remote-fixture [--port PORT] [--single-use-pairing] [--v2] [--secure-port PORT] [--host HOST:PORT]… "
          + "[--relay URL] [--relay-public URL] [--approve-links]")
    exit(0)
}
let port = value(after: "--port").flatMap(UInt16.init) ?? RemoteProtocol.defaultPort
let singleUse = arguments.contains("--single-use-pairing")
let pairingCode = "ABCDE-12345"
let fixtureToken = "yardlet-fixture-token"
nonisolated(unsafe) var retainedSecure: RemoteSecureListener?
nonisolated(unsafe) var retainedRelay: RemoteRelayClient?

let folder = FileManager.default.temporaryDirectory
    .appending(path: "yardlet-remote-fixture-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
// The ready-made device: `hello` with the fixture token skips pairing. Devices are kept in memory.
let seeded = RemoteDevice(id: "fixture-device", name: "Fixture phone", tokenHash: RemoteDeviceToken.hash(fixtureToken),
                          createdAt: Date())

// The fixture Mac's keys, the same on every run so a phone paired once stays paired.
func fixtureKey(_ label: String) -> Data { Data(SHA256.hash(data: Data(label.utf8))) }
let identity = try RemoteIdentity(noisePrivateKey: fixtureKey("yardlet-fixture-noise"),
                                  relayPrivateKey: fixtureKey("yardlet-fixture-relay"))

let bridge = RemoteFixtureBridge()
var configuration = RemoteServer.Configuration(server: RemoteServerInfo(name: "Yardlet fixture", appVersion: "fixture"),
                                               macKey: identity.noise.publicKey)
// Files a phone sends stay in this run's own folder, apart from the app's (§15.20).
configuration.uploadDirectory = folder.appending(path: "uploads", directoryHint: .isDirectory)
let server = RemoteServer(
    configuration: configuration,
    bridge: bridge,
    devices: RemoteDeviceStore(fileURL: nil, devices: [seeded]),
    audit: RemoteAuditLog(fileURL: folder.appending(path: "audit.log"))
)
await server.start()
let lifetime: TimeInterval = singleUse ? RemotePairingTicket.lifetime : 10 * 365 * 24 * 3600
let pairingSecret = fixtureKey("yardlet-fixture-pairing")
await server.openPairing(code: pairingCode, secret: pairingSecret, lifetime: lifetime, isSingleUse: singleUse)

let listeners = RemoteWebSocketListeners(server: server, port: port)
let (readiness, announce) = AsyncStream<Result<UInt16, ListenFailure>>.makeStream()
struct ListenFailure: Error { let message: String }
listeners.onStateChange = { states in
    for state in states.values {
        switch state {
        case let .ready(boundPort): announce.yield(.success(boundPort))
        case let .failed(message): announce.yield(.failure(ListenFailure(message: message)))
        case .starting: break
        }
    }
}
listeners.listen(on: [RemoteListenAddress(host: "127.0.0.1", family: .ipv4, kind: .loopback)])
for await result in readiness {
    switch result {
    case let .success(boundPort):
        print("Listening on ws://127.0.0.1:\(boundPort)/  (Android emulator: ws://10.0.2.2:\(boundPort)/)")
    case let .failure(failure):
        FileHandle.standardError.write(Data("Could not listen on 127.0.0.1:\(port): \(failure.message)\n".utf8))
        exit(1)
    }
    break
}
let url = RemotePairingURL.make(code: pairingCode, hosts: ["127.0.0.1", "10.0.2.2"], port: port, macName: "Yardlet fixture")
print("Pairing code: \(pairingCode)\(singleUse ? " (single use, 5 minutes)" : " (reusable)")")
print("Pairing URL:  \(url?.absoluteString ?? "-")")
print("Or skip pairing: {\"id\":\"1\",\"type\":\"hello\",\"protocolVersion\":1,\"token\":\"\(fixtureToken)\"}")
print("Audit log: \(folder.appending(path: "audit.log").path)")
if arguments.contains("--v2") {
    let securePort = value(after: "--secure-port").flatMap(UInt16.init) ?? RemoteProtocol.securePort
    let secure = RemoteSecureListener(server: server, staticKey: identity.noise, port: securePort, advertisement: nil,
                                      loopbackOnly: true)
    let (secureReady, announceSecure) = AsyncStream<RemoteSecureListener.State>.makeStream()
    secure.onStateChange = { announceSecure.yield($0) }
    secure.start()
    var boundSecure: UInt16 = securePort
    for await state in secureReady {
        if case let .ready(port) = state {
            boundSecure = port
            break
        }
        if case let .failed(message) = state {
            FileHandle.standardError.write(Data("Could not listen for v2 on 127.0.0.1:\(securePort): \(message)\n".utf8))
            exit(1)
        }
    }
    var hosts = arguments.indices.filter { arguments[$0] == "--host" }.compactMap { index -> String? in
        let next = arguments.index(after: index)
        return next < arguments.endIndex ? arguments[next] : nil
    }
    if hosts.isEmpty { hosts = ["10.0.2.2:\(boundSecure)", "127.0.0.1:\(boundSecure)"] }
    var relayInfo: RemoteHandshakeReply.Relay?
    if let relay = value(after: "--relay").flatMap(URL.init(string:)) {
        let client = RemoteRelayClient(server: server, identity: identity, baseURL: relay)
        client.onStateChange = { print("Relay: \($0)") }
        client.start()
        await server.setPushSender { await client.push($0) }
        relayInfo = RemoteHandshakeReply.Relay(url: value(after: "--relay-public") ?? relay.absoluteString, room: identity.room)
        retainedRelay = client
    }
    await server.setDirectory(direct: hosts, relay: relayInfo)
    retainedSecure = secure
    if arguments.contains("--approve-links") {
        await server.setAcceptsLinks(true)
        await server.setStatusHandler { status in
            guard let request = status.linkRequest else { return }
            Task {
                try? await Task.sleep(for: .seconds(3))
                print("Approving the link request from \(request.name) (\(request.code))")
                await server.answerLink(request.id, approve: true)
            }
        }
    }
    let secureURL = RemoteSecurePairingURL(macKey: identity.noise.publicKey, secret: pairingSecret, name: "Yardlet fixture",
                                           hosts: hosts, relayURL: relayInfo?.url, room: relayInfo?.room).url
    print("v2 listening on ws://127.0.0.1:\(boundSecure)/  (Noise IK, binary frames)")
    print("v2 pairing URL: \(secureURL?.absoluteString ?? "-")")
    print("v2 room: \(identity.room)")
}
signal(SIGINT) { _ in
    print("\nStopped.")
    exit(0)
}
while true {
    try? await Task.sleep(for: .seconds(3600))
}
