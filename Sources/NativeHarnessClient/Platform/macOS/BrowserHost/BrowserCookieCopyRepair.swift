import CSQLite
import Darwin
import Foundation

/// Removes, once per home, the cookies the profile cookie copy left in pairs before 2026-10-25
/// (docs/BROWSER_SESSION_ISOLATION.md 8). That copy set every host-only cookie as a domain cookie, so a site
/// that set its host-only cookie again then got two of one name, and Google's accounts site answered with
/// /CookieMismatch. In the default profile and each task profile, a copied domain cookie (`source_type` 3,
/// set through the cookie manager) goes when a host-only cookie of the same name, path and partition is there;
/// the site's own cookies and a copy without such a pair stay. That copy never made a host-only cookie, so the
/// host-only one of a pair is the site's form even when a later copy carried it (round 3). Each `Cookies` database it changes is
/// first copied, with its journal, to a folder in the Trash, and a profile whose copy fails is left as it
/// is. It runs before the browser host starts, which holds the databases open, and leaves
/// `CookieCopyRepair.json` in the root cache with the number it removed from each profile and its round, so it
/// does not run again until a later round. Round 2 (2026-10-26): until then the copy carried a profile's copied
/// domain cookie to another profile beside that site's host-only cookie, so the pairs came back. Round 3 (the
/// same day): pairs of two copies, which round 2 left, as the profiles had passed both between them.
enum BrowserCookieCopyRepair {
    static let recordName = "CookieCopyRepair.json"
    static let round = 3

    struct Record: Codable, Equatable {
        var ranAt: Date
        /// Cookies removed in each profile folder that had any.
        var removed: [String: Int]
        /// nil in the first round's record.
        var round: Int?
    }

    enum Outcome: Equatable {
        case alreadyDone
        /// A browser host holds the profiles, or a profile could not be backed up or changed: it runs again at
        /// the next start.
        case notFinished
        case done(Record)
    }

    /// The Trash of the home Yardlet keeps its data in. FileManager's Trash is the person's even when a QA run
    /// gives Yardlet a home of its own (CFFIXED_USER_HOME, which NSHomeDirectory follows).
    static var trash: URL {
        URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory).appending(path: ".Trash", directoryHint: .isDirectory)
    }

    @discardableResult
    static func runOnce(root: URL, trash: URL, now: Date = Date()) -> Outcome {
        let recordURL = root.appending(path: recordName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: recordURL) {
            // A record this code cannot read is a later round's.
            guard let last = try? decoder.decode(Record.self, from: data), (last.round ?? 1) < round else { return .alreadyDone }
        }
        guard !hostHoldsProfiles(root: root) else { return .notFinished }
        let backups = trash.appending(path: "Yardlet cookie backup \(backupTime(now))", directoryHint: .isDirectory)
        var removed: [String: Int] = [:]
        var finished = true
        for name in profileFolders(root: root) {
            let database = root.appending(path: "\(name)/Cookies")
            guard let pairs = count(database) else {
                finished = false
                continue
            }
            guard pairs > 0 else { continue }
            guard backUp(database, to: backups.appending(path: name, directoryHint: .isDirectory)),
                  let deleted = removePairs(database) else {
                finished = false
                continue
            }
            if deleted > 0 { removed[name] = deleted }
        }
        guard finished else { return .notFinished }
        let record = Record(ranAt: now, removed: removed, round: round)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(record), (try? data.write(to: recordURL, options: .atomic)) != nil else {
            return .notFinished
        }
        return .done(record)
    }

    /// The backup folder's date and time, local: `2026-10-25 18.30.05`.
    static func backupTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: date)
    }

    /// The default profile and the task profiles (`Task-<UUID>`) with a cookie database.
    private static func profileFolders(root: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []
        return names.filter { name in
            guard name == "Default" || (name.hasPrefix(BrowserTaskProfiles.folderPrefix)
                && UUID(uuidString: String(name.dropFirst(BrowserTaskProfiles.folderPrefix.count))) != nil) else { return false }
            return FileManager.default.fileExists(atPath: root.appending(path: "\(name)/Cookies").path(percentEncoded: false))
        }.sorted()
    }

    /// Chromium's lock on the root cache names the host that holds it (`<host name>-<pid>`), and stays behind
    /// a host that crashed.
    private static func hostHoldsProfiles(root: URL) -> Bool {
        let lock = root.appending(path: "SingletonLock").path(percentEncoded: false)
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: lock),
              let pid = target.split(separator: "-").last.flatMap({ pid_t($0) }), pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Copied domain cookies with a host-only cookie of the same name, path and partition.
    private static let pairs = """
        FROM cookies WHERE source_type = 3 AND substr(host_key, 1, 1) = '.' AND EXISTS (
          SELECT 1 FROM cookies host WHERE host.host_key = substr(cookies.host_key, 2) AND host.name = cookies.name
            AND host.path = cookies.path AND host.top_frame_site_key = cookies.top_frame_site_key
            AND host.has_cross_site_ancestor = cookies.has_cross_site_ancestor)
        """

    /// How many pairs the database has (0 when its table lacks the columns), nil when it cannot be read.
    private static func count(_ database: URL) -> Int? {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2(database.path(percentEncoded: false), &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return nil
        }
        sqlite3_busy_timeout(handle, 2000)
        var columns = Set<String>()
        guard query(handle, "PRAGMA table_info(cookies)", each: { statement in
            if let name = sqlite3_column_text(statement, 1) { columns.insert(String(cString: name)) }
        }) != nil else { return nil }
        let needed: Set = ["host_key", "name", "path", "top_frame_site_key", "has_cross_site_ancestor", "source_type"]
        guard needed.isSubset(of: columns) else { return 0 }
        var found = 0
        guard query(handle, "SELECT COUNT(*) " + pairs, each: { found = Int(sqlite3_column_int64($0, 0)) }) != nil else {
            return nil
        }
        return found
    }

    /// Copies the database and its journal into `folder` (a new one), true once every file is there.
    private static func backUp(_ database: URL, to folder: URL) -> Bool {
        var destination = folder
        var number = 2
        while FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            destination = folder.deletingLastPathComponent().appending(path: "\(folder.lastPathComponent) \(number)")
            number += 1
        }
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for suffix in ["", "-journal", "-wal"] {
                let file = database.deletingLastPathComponent().appending(path: database.lastPathComponent + suffix)
                guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { continue }
                try FileManager.default.copyItem(at: file, to: destination.appending(path: file.lastPathComponent))
            }
            return true
        } catch {
            return false
        }
    }

    /// Deletes the pairs in one transaction: how many went, nil when nothing changed.
    private static func removePairs(_ database: URL) -> Int? {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2(database.path(percentEncoded: false), &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            return nil
        }
        sqlite3_busy_timeout(handle, 2000)
        guard sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return nil }
        guard sqlite3_exec(handle, "DELETE " + pairs, nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            return nil
        }
        let deleted = Int(sqlite3_changes(handle))
        guard sqlite3_exec(handle, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            return nil
        }
        return deleted
    }

    /// Runs `sql`, calling `each` for every row: the number of rows, nil on an error.
    private static func query(_ handle: OpaquePointer?, _ sql: String, each: (OpaquePointer?) -> Void) -> Int? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var rows = 0
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                each(statement)
                rows += 1
            case SQLITE_DONE:
                return rows
            default:
                return nil
            }
        }
    }
}
