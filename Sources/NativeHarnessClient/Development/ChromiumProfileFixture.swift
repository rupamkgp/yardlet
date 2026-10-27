#if DEBUG
import CommonCrypto
import CryptoKit
import CSQLite
import Foundation

/// A made-up Chromium data folder for the tests and QA of `BrowserLoginImport`: `Local State` naming its profiles and,
/// in each, a `Cookies` database in Chromium 154's schema (version 24) whose values are encrypted as Chromium encrypts
/// them on macOS, under a test password instead of a keychain item's.
enum ChromiumProfileFixture {
    struct Cookie {
        /// As Chromium stores it: a leading dot for a domain cookie.
        var host: String
        var name: String
        var value: String
        var path = "/"
        var secure = true
        var httpOnly = true
        /// Chromium's: -1 unspecified, 0 none, 1 lax, 2 strict.
        var sameSite = 0
        /// Nil for a session cookie.
        var expires: Date? = Date().addingTimeInterval(86_400)
        /// The top-level site a partitioned (CHIPS) cookie is kept under.
        var partitionedUnder: String?
    }

    struct Profile {
        var folder: String
        var name: String
        var cookies: [Cookie]
        /// Chromium 96 and later keep the database in `Network`; Whale keeps it beside the profile.
        var inNetworkFolder = false
    }

    /// Writes the browser's folder at `root` (Application Support's `<browser folder>`).
    static func make(at root: URL, profiles: [Profile], lastUsed: String, password: Data) throws {
        var cache: [String: Any] = [:]
        for profile in profiles { cache[profile.folder] = ["name": profile.name] }
        let state: [String: Any] = ["profile": ["info_cache": cache, "last_used": lastUsed,
                                                "profiles_order": profiles.map(\.folder)]]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: state).write(to: root.appending(path: "Local State"))
        let key = BrowserLoginImport.cookieKey(password: password) ?? Data()
        for profile in profiles {
            let folder = root.appending(path: profile.inNetworkFolder ? "\(profile.folder)/Network" : profile.folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try writeDatabase(folder.appending(path: "Cookies"), cookies: profile.cookies, key: key)
        }
    }

    /// Chromium's `v10` value of a database at version 24: the host's SHA-256, then the value, under AES-128-CBC.
    static func encrypt(_ value: String, key: Data, hostKey: String) -> Data {
        let plain = Data(SHA256.hash(data: Data(hostKey.utf8))) + Data(value.utf8)
        var output = Data(count: plain.count + kCCBlockSizeAES128)
        var written = 0
        let outputSize = output.count
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        _ = output.withUnsafeMutableBytes { out in
            plain.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, iv, input.baseAddress, plain.count, out.baseAddress, outputSize, &written)
                }
            }
        }
        output.count = written
        return Data("v10".utf8) + output
    }

    private static func writeDatabase(_ url: URL, cookies: [Cookie], key: Data) throws {
        try? FileManager.default.removeItem(at: url)
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open(url.path(percentEncoded: false), &handle) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        let schema = """
            CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
            INSERT INTO meta VALUES('version', '24'), ('last_compatible_version', '24');
            CREATE TABLE cookies(creation_utc INTEGER NOT NULL, host_key TEXT NOT NULL, top_frame_site_key TEXT NOT NULL,
              name TEXT NOT NULL, value TEXT NOT NULL, encrypted_value BLOB NOT NULL, path TEXT NOT NULL,
              expires_utc INTEGER NOT NULL, is_secure INTEGER NOT NULL, is_httponly INTEGER NOT NULL,
              last_access_utc INTEGER NOT NULL, has_expires INTEGER NOT NULL, is_persistent INTEGER NOT NULL,
              priority INTEGER NOT NULL, samesite INTEGER NOT NULL, source_scheme INTEGER NOT NULL,
              source_port INTEGER NOT NULL, last_update_utc INTEGER NOT NULL, source_type INTEGER NOT NULL,
              has_cross_site_ancestor INTEGER NOT NULL);
            """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        var statement: OpaquePointer?
        let insert = "INSERT INTO cookies VALUES(?, ?, ?, ?, '', ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, 2, 443, ?, 1, 0)"
        guard sqlite3_prepare_v2(handle, insert, -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, cookie) in cookies.enumerated() {
            let now = chromiumTime(Date()) - Int64(cookies.count - index) * 1_000_000
            let encrypted = encrypt(cookie.value, key: key, hostKey: cookie.host)
            sqlite3_reset(statement)
            sqlite3_bind_int64(statement, 1, now)
            sqlite3_bind_text(statement, 2, cookie.host, -1, transient)
            sqlite3_bind_text(statement, 3, cookie.partitionedUnder ?? "", -1, transient)
            sqlite3_bind_text(statement, 4, cookie.name, -1, transient)
            _ = encrypted.withUnsafeBytes { sqlite3_bind_blob(statement, 5, $0.baseAddress, Int32(encrypted.count), transient) }
            sqlite3_bind_text(statement, 6, cookie.path, -1, transient)
            sqlite3_bind_int64(statement, 7, cookie.expires.map(chromiumTime) ?? 0)
            sqlite3_bind_int(statement, 8, cookie.secure ? 1 : 0)
            sqlite3_bind_int(statement, 9, cookie.httpOnly ? 1 : 0)
            sqlite3_bind_int64(statement, 10, now)
            sqlite3_bind_int(statement, 11, cookie.expires == nil ? 0 : 1)
            sqlite3_bind_int(statement, 12, cookie.expires == nil ? 0 : 1)
            sqlite3_bind_int(statement, 13, Int32(cookie.sameSite))
            sqlite3_bind_int64(statement, 14, now)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
        }
    }

    /// Chromium's microseconds since 1601.
    static func chromiumTime(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
    }
}
#endif
