import Foundation

typealias MuseRawFrame = ACPRawFrame

struct MuseLaunchConfiguration: Sendable {
    let arguments: [String]
    let workspaceURL: URL
}

protocol MuseTransport: Actor {
    func start(_ configuration: MuseLaunchConfiguration) async throws
    func request(_ value: JSONValue, id: Int64) async throws -> JSONValue
    func send(_ value: JSONValue) async throws
    func messages() async -> AsyncStream<MuseRawFrame>
    func stop() async
}

/// MSP and ACP both use newline-delimited JSON-RPC 2.0 over stdio, so this thin binding reuses
/// Yardlet's process ownership, correlation, timeout, stderr, and process-tree cleanup machinery.
actor MuseProcessTransport: MuseTransport {
    private let core: ACPProcessTransport

    init(executableURL: URL, requestTimeout: Duration = .seconds(300)) {
        core = ACPProcessTransport(
            executableURL: executableURL,
            requestTimeout: requestTimeout
        )
    }

    func start(_ configuration: MuseLaunchConfiguration) async throws {
        try await core.start(
            ACPLaunchConfiguration(
                arguments: configuration.arguments,
                workspaceURL: configuration.workspaceURL
            )
        )
    }

    func request(_ value: JSONValue, id: Int64) async throws -> JSONValue {
        try await core.request(value, id: id)
    }

    func send(_ value: JSONValue) async throws {
        try await core.send(value)
    }

    func messages() async -> AsyncStream<MuseRawFrame> {
        await core.messages()
    }

    func stop() async {
        await core.stop()
    }
}

/// One monotonic command-ID source per MSP connection, matching the official SDK's UUIDv7
/// construction and sequence behavior.
struct MuseCommandIDMint: Sendable {
    private var lastMilliseconds: Int64 = -1
    private var sequence: UInt16 = 0

    mutating func next(now: Date = Date()) -> String {
        var milliseconds = Int64(now.timeIntervalSince1970 * 1_000)
        if milliseconds <= lastMilliseconds {
            milliseconds = lastMilliseconds
            sequence &+= 1
            if sequence > 0x0FFF {
                milliseconds += 1
                sequence = 0
            }
        } else {
            sequence = 0
        }
        lastMilliseconds = milliseconds

        var randomUUID = UUID().uuid
        var bytes = withUnsafeBytes(of: &randomUUID) { Array($0) }
        var timestamp = UInt64(bitPattern: milliseconds)
        for index in stride(from: 5, through: 0, by: -1) {
            bytes[index] = UInt8(timestamp & 0xFF)
            timestamp >>= 8
        }
        bytes[6] = 0x70 | UInt8((sequence >> 8) & 0x0F)
        bytes[7] = UInt8(sequence & 0xFF)
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return [
            String(hex.prefix(8)),
            String(hex.dropFirst(8).prefix(4)),
            String(hex.dropFirst(12).prefix(4)),
            String(hex.dropFirst(16).prefix(4)),
            String(hex.dropFirst(20).prefix(12))
        ].joined(separator: "-")
    }
}
