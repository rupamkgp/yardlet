import CryptoKit
import Foundation
import Security

// Pairing (§3): a one-time secret the Mac shows as a QR code and a short code, exchanged once for a
// random device token. The Mac keeps only the token's SHA-256.

public enum RemotePairingCode {
    /// Crockford base32: no I, L, O or U.
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    public static let length = 10

    /// A new secret: ten random Crockford base32 characters (50 bits).
    public static func generate() -> String {
        let bytes = RemoteRandom.bytes(length)
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    /// `XXXXX-XXXXX`, as Settings shows it.
    public static func display(_ code: String) -> String {
        let normalized = normalize(code) ?? code
        guard normalized.count == length else { return normalized }
        return String(normalized.prefix(5)) + "-" + String(normalized.suffix(5))
    }

    /// The code as typed, read as Crockford base32: any case, dashes and spaces ignored, O read as 0
    /// and I or L as 1. Nil when it holds anything else.
    public static func normalize(_ typed: String) -> String? {
        var result = ""
        for character in typed.uppercased() {
            switch character {
            case "-", " ": continue
            case "O": result.append("0")
            case "I", "L": result.append("1")
            default:
                guard alphabet.contains(character) else { return nil }
                result.append(character)
            }
        }
        return result
    }

    /// Compares in time that does not depend on where they differ.
    public static func matches(_ typed: String, _ secret: String) -> Bool {
        guard let typed = normalize(typed) else { return false }
        let left = Array(typed.utf8)
        let right = Array(secret.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }
}

public enum RemoteRandom {
    public static func bytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if status != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max, using: &generator) }
        }
        return bytes
    }
}

public enum RemoteDeviceToken {
    /// 32 random bytes, base64url without padding (43 characters).
    public static func generate() -> String {
        Data(RemoteRandom.bytes(32)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// What the Mac stores in place of the token.
    public static func hash(_ token: String) -> String {
        RemoteDigest.sha256(token)
    }
}

public enum RemoteDigest {
    /// SHA-256 of the text's UTF-8, hex.
    public static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The one pairing open at a time: a v1 code and a v2 secret, either spends it.
public struct RemotePairingTicket: Equatable, Sendable {
    /// The normalized secret.
    public var code: String
    /// The v2 QR's secret (§12): 32 random bytes.
    public var secret: Data
    public var expiresAt: Date
    public var attemptsLeft: Int
    /// Closed after one successful use (the Mac); the fixture can keep it open.
    public var isSingleUse: Bool
    /// The phone key that used it on v2, which may use it again until it expires (§12).
    public var pairedKey: Data?

    public static let lifetime: TimeInterval = 5 * 60
    public static let attempts = 5

    public init(code: String = RemotePairingCode.generate(), secret: Data = Data(RemoteRandom.bytes(32)), expiresAt: Date,
                attemptsLeft: Int = RemotePairingTicket.attempts, isSingleUse: Bool = true) {
        self.code = code
        self.secret = secret
        self.expiresAt = expiresAt
        self.attemptsLeft = attemptsLeft
        self.isSingleUse = isSingleUse
    }

    public var displayCode: String { RemotePairingCode.display(code) }
}

/// What the QR code holds (§3.1).
public enum RemotePairingURL {
    public static func make(code: String, hosts: [String], port: UInt16, macName: String) -> URL? {
        var components = URLComponents()
        components.scheme = RemoteProtocol.pairingScheme
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: String(RemoteProtocol.version)),
            URLQueryItem(name: "code", value: RemotePairingCode.display(code)),
            URLQueryItem(name: "port", value: String(port))
        ] + hosts.map { URLQueryItem(name: "host", value: $0) }
            + [URLQueryItem(name: "name", value: macName)]
        // `URLComponents` leaves `:` in IPv6 hosts and spaces escaped as %20, which every reader takes.
        return components.url
    }

    public struct Parsed: Equatable, Sendable {
        public var version: Int
        public var code: String
        public var port: UInt16
        public var hosts: [String]
        public var name: String?
    }

    public static func parse(_ url: URL) -> Parsed? {
        guard url.scheme == RemoteProtocol.pairingScheme, url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let version = items.first(where: { $0.name == "v" })?.value.flatMap(Int.init),
              let code = items.first(where: { $0.name == "code" })?.value,
              let port = items.first(where: { $0.name == "port" })?.value.flatMap(UInt16.init) else { return nil }
        return Parsed(version: version, code: code, port: port,
                      hosts: items.filter { $0.name == "host" }.compactMap(\.value),
                      name: items.first { $0.name == "name" }?.value)
    }
}

/// What the v2 QR code holds (§12).
public struct RemoteSecurePairingURL: Equatable, Sendable {
    public var macKey: Data
    public var secret: Data
    public var name: String
    /// `host:port`, in the order to try.
    public var hosts: [String]
    public var relayURL: String?
    public var room: String?

    public init(macKey: Data, secret: Data, name: String, hosts: [String], relayURL: String? = nil, room: String? = nil) {
        self.macKey = macKey
        self.secret = secret
        self.name = name
        self.hosts = hosts
        self.relayURL = relayURL
        self.room = room
    }

    public var url: URL? {
        var components = URLComponents()
        components.scheme = RemoteProtocol.pairingScheme
        components.host = "pair"
        var items = [
            URLQueryItem(name: "v", value: String(RemoteProtocol.secureVersion)),
            URLQueryItem(name: "k", value: RemoteEncoding.base64url(macKey)),
            URLQueryItem(name: "s", value: RemoteEncoding.base64url(secret)),
            URLQueryItem(name: "n", value: name)
        ]
        items += hosts.map { URLQueryItem(name: "h", value: $0) }
        if let relayURL, let room {
            items += [URLQueryItem(name: "r", value: relayURL), URLQueryItem(name: "i", value: room)]
        }
        components.queryItems = items
        // `URLComponents` leaves `:` and `/` in query values, which every reader takes.
        return components.url
    }

    public static func parse(_ url: URL) -> RemoteSecurePairingURL? {
        guard url.scheme == RemoteProtocol.pairingScheme, url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.first(where: { $0.name == "v" })?.value == String(RemoteProtocol.secureVersion),
              let key = items.first(where: { $0.name == "k" })?.value.flatMap(RemoteEncoding.data(base64url:)), key.count == 32,
              let secret = items.first(where: { $0.name == "s" })?.value.flatMap(RemoteEncoding.data(base64url:)),
              secret.count == 32 else { return nil }
        let relay = items.first { $0.name == "r" }?.value
        let room = items.first { $0.name == "i" }?.value
        return RemoteSecurePairingURL(macKey: key, secret: secret, name: items.first { $0.name == "n" }?.value ?? "Mac",
                                      hosts: items.filter { $0.name == "h" }.compactMap(\.value),
                                      relayURL: relay != nil && room != nil ? relay : nil,
                                      room: relay != nil && room != nil ? room : nil)
    }
}

/// The six digits both sides show for a link request (§12.1).
public enum RemoteLinkCode {
    public static func code(macKey: Data, phoneKey: Data) -> String {
        let digest = Array(SHA256.hash(data: Data("yardlet-link/1".utf8) + macKey + phoneKey))
        let value = UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3])
        return String(format: "%06u", value % 1_000_000)
    }
}

// MARK: - Devices

/// Where a v2 device's pushes go (§15.6).
public struct RemotePushRegistration: Codable, Equatable, Sendable {
    public var provider: String
    public var token: String
    /// The push key, base64url.
    public var key: String

    public init(provider: String, token: String, key: String) {
        self.provider = provider
        self.token = token
        self.key = key
    }
}

public struct RemoteDevice: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// v1: SHA-256 of the device token, hex.
    public var tokenHash: String?
    /// v2: the phone's static public key, base64url. The Mac holds nothing secret of the phone's.
    public var publicKey: String?
    public var platform: String?
    public var push: RemotePushRegistration?
    public var createdAt: Date
    public var lastSeenAt: Date?

    public init(id: String = UUID().uuidString, name: String, tokenHash: String? = nil, publicKey: String? = nil,
                platform: String? = nil, createdAt: Date, lastSeenAt: Date? = nil) {
        self.id = id
        self.name = name
        self.tokenHash = tokenHash
        self.publicKey = publicKey
        self.platform = platform
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
    }

    /// Paired over v2.
    public var isSecure: Bool { publicKey != nil }
}

/// The paired devices, in a file only the person can read (`~/.yardlet/remote/devices.json` for the
/// app; a test or the fixture passes its own folder, or none to keep them in memory).
public actor RemoteDeviceStore {
    private struct File: Codable {
        var version = 2
        var devices: [RemoteDevice]
    }

    private let fileURL: URL?
    private var devices: [RemoteDevice]
    /// A seen time is written at most this often per device.
    private let seenWriteInterval: TimeInterval = 60

    /// `devices` are the ones a store without a file starts with (the fixture's ready-made device).
    public init(fileURL: URL?, devices seeded: [RemoteDevice] = []) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let file = try? JSONDecoder.remoteDates.decode(File.self, from: data) {
            devices = file.devices
        } else {
            devices = seeded
        }
    }

    public func all() -> [RemoteDevice] { devices }

    /// A new device and its token, which is shown to the device once and never stored.
    public func add(name: String, now: Date = Date()) -> (device: RemoteDevice, token: String) {
        let token = RemoteDeviceToken.generate()
        let device = RemoteDevice(name: name.isEmpty ? "Phone" : name, tokenHash: RemoteDeviceToken.hash(token),
                                  createdAt: now, lastSeenAt: now)
        devices.append(device)
        save()
        return (device, token)
    }

    /// The device a token belongs to, marked seen.
    public func authenticate(_ token: String, now: Date = Date()) -> RemoteDevice? {
        let hash = RemoteDeviceToken.hash(token)
        guard let index = devices.firstIndex(where: { $0.tokenHash.map { Self.equal($0, hash) } == true }) else { return nil }
        markSeen(at: index, now: now, force: true)
        return devices[index]
    }

    /// A v2 device by its public key, marked seen and renamed to what it calls itself now.
    public func authenticate(publicKey: Data, name: String?, now: Date = Date()) -> RemoteDevice? {
        let key = RemoteEncoding.base64url(publicKey)
        guard let index = devices.firstIndex(where: { $0.publicKey == key }) else { return nil }
        if let name, !name.isEmpty, devices[index].name != name { devices[index].name = name }
        markSeen(at: index, now: now, force: true)
        return devices[index]
    }

    /// A new v2 device, or the one this key already is.
    public func addSecure(name: String, publicKey: Data, platform: String?, now: Date = Date()) -> RemoteDevice {
        if let device = authenticate(publicKey: publicKey, name: name, now: now) { return device }
        let device = RemoteDevice(name: name.isEmpty ? "Phone" : name, publicKey: RemoteEncoding.base64url(publicKey),
                                  platform: platform, createdAt: now, lastSeenAt: now)
        devices.append(device)
        save()
        return device
    }

    public func device(_ id: String) -> RemoteDevice? {
        devices.first { $0.id == id }
    }

    /// Stores where the device's pushes go and returns its push key, made once and kept.
    public func setPush(_ id: String, provider: String, token: String) -> Data? {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return nil }
        let key = devices[index].push.flatMap { RemoteEncoding.data(base64url: $0.key) } ?? RemotePushSeal.newKey()
        devices[index].push = RemotePushRegistration(provider: provider, token: token, key: RemoteEncoding.base64url(key))
        save()
        return key
    }

    public func clearPush(_ id: String) {
        guard let index = devices.firstIndex(where: { $0.id == id }), devices[index].push != nil else { return }
        devices[index].push = nil
        save()
    }

    /// Forgets a push token the push service no longer knows, if it is still the device's.
    public func dropPushToken(_ token: String) {
        guard let index = devices.firstIndex(where: { $0.push?.token == token }) else { return }
        devices[index].push = nil
        save()
    }

    public func seen(_ id: String, now: Date = Date()) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        markSeen(at: index, now: now, force: false)
    }

    @discardableResult
    public func remove(_ id: String) -> Bool {
        let count = devices.count
        devices.removeAll { $0.id == id }
        guard devices.count != count else { return false }
        save()
        return true
    }

    private func markSeen(at index: Int, now: Date, force: Bool) {
        if !force, let last = devices[index].lastSeenAt, now.timeIntervalSince(last) < seenWriteInterval { return }
        devices[index].lastSeenAt = now
        save()
    }

    private func save() {
        guard let fileURL else { return }
        let folder = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder.remoteDates.encode(File(devices: devices)) else { return }
        try? data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private static func equal(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }
}

extension JSONEncoder {
    static var remoteDates: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }
}

extension JSONDecoder {
    static var remoteDates: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
