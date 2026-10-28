import CSQLite
import Foundation
import XCTest
@testable import NativeHarnessClient

/// The one-time removal of addresses that carried a vault password deletes a person's history: only entries whose
/// address carries a password whole (a query or fragment value, a path segment, an address inside a parameter) may
/// go, with what hangs on them, and it runs once (docs/BROWSER_VAULT_DESIGN.md, "Filled values and addresses").
/// Databases in a temporary folder and preferences of the test's own only.
@MainActor
final class BrowserFilledValueCleanupTests: XCTestCase {
    private var folder: URL!
    private var defaults: UserDefaults!
    private var suite = ""
    private var root: URL { folder.appending(path: "Browser") }
    private let task = "Task-" + UUID().uuidString
    private let password = "p@ss word+1!"

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "BrowserFilledValueCleanupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: task), withIntermediateDirectories: true)
        suite = "BrowserFilledValueCleanupTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }

    private func execute(_ file: String, _ sql: String) {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appending(path: file).path(percentEncoded: false), &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(handle)))
    }

    private func column(_ file: String, _ sql: String) -> [String] {
        var handle: OpaquePointer?
        guard sqlite3_open(root.appending(path: file).path(percentEncoded: false), &handle) == SQLITE_OK else { return [] }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            values.append(sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "")
        }
        return values
    }

    func testRemovesOnlyAddressesThatCarryAVaultPasswordWholeAndRunsOnce() throws {
        // Sent by a GET form; inside a sign-in page's return address; a short password whole, and only in a longer value.
        let form = "https://app.example.com/login?email=ada%40example.com&password=p%40ss+word%2B1%21"
        let nested = "https://app.example.com/sso?returnTo=https%3A%2F%2Fapp.example.com%2Flogin%3Fpassword%3Dp%2540ss%2520word%252B1%2521"
        let pin = "https://shop.test/unlock?pin=4321#done"
        let kept = ["https://app.example.com/home", "https://shop.test/item/43210?ref=4321x", "https://search.test/?q=p%40ss"]
        let urls = [form, nested, pin] + kept
        execute("\(task)/History", """
            CREATE TABLE urls(id INTEGER PRIMARY KEY AUTOINCREMENT, url LONGVARCHAR, title LONGVARCHAR);
            CREATE TABLE visits(id INTEGER PRIMARY KEY AUTOINCREMENT, url INTEGER NOT NULL);
            CREATE TABLE visit_source(id INTEGER PRIMARY KEY, source INTEGER NOT NULL);
            CREATE TABLE visited_links(id INTEGER PRIMARY KEY AUTOINCREMENT, link_url_id INTEGER NOT NULL,
              top_level_url LONGVARCHAR NOT NULL, frame_url LONGVARCHAR NOT NULL);
            CREATE TABLE segments(id INTEGER PRIMARY KEY, name VARCHAR, url_id INTEGER NON NULL);
            CREATE TABLE segment_usage(id INTEGER PRIMARY KEY AUTOINCREMENT, segment_id INTEGER NOT NULL);
            \(urls.enumerated().map { "INSERT INTO urls VALUES(\($0.offset + 1), '\($0.element)', 'Page \($0.offset + 1)');" }.joined())
            INSERT INTO visits VALUES(1, 1); INSERT INTO visits VALUES(2, 1); INSERT INTO visits VALUES(3, 4);
            INSERT INTO visit_source VALUES(1, 0); INSERT INTO visit_source VALUES(3, 0);
            INSERT INTO visited_links VALUES(1, 4, '\(form)', '\(form)');
            INSERT INTO visited_links VALUES(2, 1, 'https://app.example.com/', 'https://app.example.com/');
            INSERT INTO visited_links VALUES(3, 5, 'https://shop.test/', 'https://shop.test/');
            INSERT INTO segments VALUES(1, 'app.example.com', 1); INSERT INTO segment_usage VALUES(1, 1);
            """)
        execute("\(task)/Favicons", """
            CREATE TABLE icon_mapping(id INTEGER PRIMARY KEY, page_url LONGVARCHAR NOT NULL, icon_id INTEGER);
            INSERT INTO icon_mapping VALUES(1, '\(form)', 1); INSERT INTO icon_mapping VALUES(2, '\(kept[0])', 1);
            """)
        try JSONSerialization.data(withJSONObject: [
            "pages": [["url": form, "title": "Signed in", "visitCount": 1], ["url": kept[0], "title": "Home", "visitCount": 2]],
            "searches": [["terms": password, "count": 1], ["terms": "weather", "count": 3]]
        ]).write(to: root.appending(path: "AddressHistory.json"))
        let workspace = "Yardlet.taskWorkspace.\(UUID().uuidString)"
        defaults.set(try JSONSerialization.data(withJSONObject: [
            "version": 1, "layout": ["kept": true],
            "browser": ["address": form, "pages": [
                ["key": UUID().uuidString, "address": form, "title": "Signed in"],
                ["key": UUID().uuidString, "address": kept[0], "title": "Home"]
            ]]
        ]), forKey: workspace)

        let outcome = BrowserFilledValueCleanup.run(root: root, passwords: [password, "4321", "abc"], defaults: defaults)
        guard case .done(let record) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(column("\(task)/History", "SELECT url FROM urls ORDER BY id"), kept)
        XCTAssertEqual(column("\(task)/History", "SELECT id FROM visits"), ["3"], "the visits of the addresses that went")
        XCTAssertEqual(column("\(task)/History", "SELECT id FROM visit_source"), ["3"])
        XCTAssertEqual(column("\(task)/History", "SELECT id FROM visited_links"), ["3"],
                       "a link on such a page, and a link to one")
        XCTAssertEqual(column("\(task)/History", "SELECT count(*) FROM segments"), ["0"])
        XCTAssertEqual(column("\(task)/History", "SELECT count(*) FROM segment_usage"), ["0"])
        XCTAssertEqual(column("\(task)/Favicons", "SELECT page_url FROM icon_mapping"), [kept[0]])

        let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: workspace))) as? [String: Any])
        XCTAssertEqual((snapshot["layout"] as? [String: Bool])?["kept"], true, "the rest of the snapshot stays")
        let browser = try XCTUnwrap(snapshot["browser"] as? [String: Any])
        XCTAssertEqual(browser["address"] as? String, "https://app.example.com/login")
        let pages = try XCTUnwrap(browser["pages"] as? [[String: Any]])
        XCTAssertEqual(pages.map { $0["address"] as? String }, ["https://app.example.com/login", kept[0]])
        XCTAssertEqual(pages.map { $0["title"] as? String }, ["", "Home"])

        let history = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appending(path: "AddressHistory.json"))) as? [String: [[String: Any]]])
        XCTAssertEqual(history["pages"]?.map { $0["url"] as? String }, [kept[0]])
        XCTAssertEqual(history["searches"]?.map { $0["terms"] as? String }, ["weather"])

        XCTAssertEqual(record.removed["\(task)/Favicons"], 1)
        XCTAssertEqual(record.removed["AddressHistory.json"], 2)
        XCTAssertEqual(record.removed["Task workspaces"], 2)
        XCTAssertEqual(BrowserFilledValueCleanup.run(root: root, passwords: [password], defaults: defaults), .alreadyDone)
    }
}
