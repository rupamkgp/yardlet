import CSQLite
import Darwin
import Foundation
import XCTest
@testable import NativeHarnessClient

/// The one-time removal of the cookie pairs the profile cookie copy left before 2026-10-25 deletes a person's
/// cookies: only copied domain cookies that pair with a host-only one may go, each changed database is in the
/// Trash first, and it runs once (docs/BROWSER_SESSION_ISOLATION.md 8). Databases in a temporary folder only.
final class BrowserCookieCopyRepairTests: XCTestCase {
    private var folder: URL!
    private var root: URL { folder.appending(path: "Browser") }
    private var trash: URL { folder.appending(path: "Trash") }
    private let task = "Task-" + UUID().uuidString
    private let now = Date(timeIntervalSince1970: 1_792_900_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "BrowserCookieCopyRepairTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A cookie row: host, name, source type (1 HTTP, 2 script, 3 set through the cookie manager), partition.
    private typealias Row = (host: String, name: String, source: Int, partition: String)

    /// A `Cookies` database with Chromium 154's table (schema 24) and its unique index.
    private func makeDatabase(_ profile: String, _ rows: [Row], journal: Bool = false) throws {
        let directory = root.appending(path: profile)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appending(path: "Cookies").path(percentEncoded: false), &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var sql = """
            CREATE TABLE cookies(creation_utc INTEGER NOT NULL, host_key TEXT NOT NULL, top_frame_site_key TEXT NOT NULL,
              name TEXT NOT NULL, value TEXT NOT NULL, encrypted_value BLOB NOT NULL, path TEXT NOT NULL,
              expires_utc INTEGER NOT NULL, is_secure INTEGER NOT NULL, is_httponly INTEGER NOT NULL,
              last_access_utc INTEGER NOT NULL, has_expires INTEGER NOT NULL, is_persistent INTEGER NOT NULL,
              priority INTEGER NOT NULL, samesite INTEGER NOT NULL, source_scheme INTEGER NOT NULL,
              source_port INTEGER NOT NULL, last_update_utc INTEGER NOT NULL, source_type INTEGER NOT NULL,
              has_cross_site_ancestor INTEGER NOT NULL);
            CREATE UNIQUE INDEX cookies_unique_index ON cookies(host_key, top_frame_site_key, has_cross_site_ancestor,
              name, path, source_scheme, source_port);
            """
        for (index, row) in rows.enumerated() {
            sql += "INSERT INTO cookies VALUES(\(index), '\(row.host)', '\(row.partition)', '\(row.name)', '', X'00', '/', "
                + "0, 1, 1, 0, 1, 1, 1, -1, 2, 443, 0, \(row.source), 0);"
        }
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
        // Chromium truncates its journal after each write.
        if journal { try Data().write(to: directory.appending(path: "Cookies-journal")) }
    }

    private func cookies(_ profile: String, in base: URL? = nil) -> [String] {
        let database = (base ?? root).appending(path: "\(profile)/Cookies")
        var handle: OpaquePointer?
        guard sqlite3_open(database.path(percentEncoded: false), &handle) == SQLITE_OK else { return [] }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(handle, "SELECT host_key, name FROM cookies ORDER BY host_key, name", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(String(cString: sqlite3_column_text(statement, 0)) + " " + String(cString: sqlite3_column_text(statement, 1)))
        }
        return rows
    }

    func testRemovesOnlyCopiedDomainCookiesPairedWithAHostOnlyOneAfterBackingUpAndOnce() throws {
        try makeDatabase("Default", [
            ("accounts.example.com", "signin", 1, ""), (".accounts.example.com", "signin", 3, ""),  // the copy's pair goes
            ("search.example.com", "pref", 2, ""), (".search.example.com", "pref", 2, ""),          // the site's own pair
            (".lone.example.com", "copied", 3, ""),                                                  // a copy without a pair
            ("x.example.com", "both", 3, ""), (".x.example.com", "both", 1, ""),                     // the domain one is the site's
            ("y.example.com", "carried", 3, ""), (".y.example.com", "carried", 3, ""),               // two copies: the domain one goes
            ("w.example.net", "chips", 1, "https://a.test"), (".w.example.net", "chips", 3, "")       // another partition
        ])
        try makeDatabase(task, [("accounts.example.com", "signin", 1, ""), (".accounts.example.com", "signin", 3, "")],
                         journal: true)
        try makeDatabase("Profile 1", [("a.example.com", "n", 1, ""), (".a.example.com", "n", 3, "")])
        try makeDatabase("Task-not-a-key", [("a.example.com", "n", 1, ""), (".a.example.com", "n", 3, "")])
        let untouched = cookies("Default").filter { $0 != ".accounts.example.com signin" && $0 != ".y.example.com carried" }

        let outcome = BrowserCookieCopyRepair.runOnce(root: root, trash: trash, now: now)
        XCTAssertEqual(outcome, .done(.init(ranAt: now, removed: ["Default": 2, task: 1], round: 3)))
        XCTAssertEqual(cookies("Default"), untouched)
        XCTAssertEqual(cookies(task), ["accounts.example.com signin"])
        XCTAssertEqual(cookies("Profile 1").count, 2, "only the default profile and task profiles")
        XCTAssertEqual(cookies("Task-not-a-key").count, 2)

        // Each changed database, with its journal, is in the Trash as it was.
        let backups = trash.appending(path: "Yardlet cookie backup \(BrowserCookieCopyRepair.backupTime(now))")
        XCTAssertEqual(cookies("Default", in: backups).count, 11)
        XCTAssertEqual(cookies(task, in: backups).count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backups.appending(path: "\(task)/Cookies-journal").path(percentEncoded: false)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.appending(path: "Profile 1").path(percentEncoded: false)))

        // The record holds counts only, and the repair does not run again.
        let record = try String(contentsOf: root.appending(path: BrowserCookieCopyRepair.recordName), encoding: .utf8)
        XCTAssertFalse(record.contains("example"))
        try FileManager.default.removeItem(at: root.appending(path: "Default"))
        try makeDatabase("Default", [("accounts.example.com", "signin", 1, ""), (".accounts.example.com", "signin", 3, "")])
        XCTAssertEqual(BrowserCookieCopyRepair.runOnce(root: root, trash: trash, now: now), .alreadyDone)
        XCTAssertEqual(cookies("Default").count, 2)

        // An earlier round's record lets this round run once: the first (no round), as the copy spread the pairs
        // again until 2026-10-26, and round 2, which left pairs of two copies.
        let second = #"{"ranAt":"2026-10-26T13:57:02Z","removed":{"Default":3},"round":2}"#
        try Data(second.utf8).write(to: root.appending(path: BrowserCookieCopyRepair.recordName))
        XCTAssertEqual(BrowserCookieCopyRepair.runOnce(root: root, trash: trash, now: now),
                       .done(.init(ranAt: now, removed: ["Default": 1], round: 3)))
        XCTAssertEqual(cookies("Default"), ["accounts.example.com signin"])
    }

    func testLeavesEverythingAndRunsAgainWhenAHostHoldsTheProfilesOrTheBackupFails() throws {
        try makeDatabase("Default", [("accounts.example.com", "signin", 1, ""), (".accounts.example.com", "signin", 3, "")])
        let lock = root.appending(path: "SingletonLock").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(atPath: lock, withDestinationPath: "host-\(getpid())")
        XCTAssertEqual(BrowserCookieCopyRepair.runOnce(root: root, trash: trash, now: now), .notFinished)
        XCTAssertEqual(cookies("Default").count, 2)

        // A crashed host's lock stays behind; a Trash it cannot write to keeps the database as it is.
        try FileManager.default.removeItem(atPath: lock)
        try FileManager.default.createSymbolicLink(atPath: lock, withDestinationPath: "host-999999")
        try Data().write(to: trash)
        XCTAssertEqual(BrowserCookieCopyRepair.runOnce(root: root, trash: trash, now: now), .notFinished)
        XCTAssertEqual(cookies("Default").count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: BrowserCookieCopyRepair.recordName).path(percentEncoded: false)))

        try FileManager.default.removeItem(at: trash)
        XCTAssertEqual(BrowserCookieCopyRepair.runOnce(root: root, trash: trash, now: now),
                       .done(.init(ranAt: now, removed: ["Default": 1], round: 3)))
        XCTAssertEqual(cookies("Default"), ["accounts.example.com signin"])
    }
}
