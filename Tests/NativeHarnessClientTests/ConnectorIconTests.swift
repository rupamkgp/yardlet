import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// Connector pictures (docs/CONNECTORS.md, "Icons"): the icons a server declares about itself, then the
/// directory's icon on the service's own site, never another site's; fetched once, kept on disk,
/// and a miss not asked for again for a day. No network: the fetches are counted fakes.
///
/// `YARDLET_CONNECTOR_ICONS_LIVE=1` also fetches every directory icon from the services' own sites
/// and draws Settings → Connectors, Add connector, and the composer's list with them into
/// `.build/ui-polish-qa/after/live-icons/`, light and dark.
@MainActor
final class ConnectorIconTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "connector-icons-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    // MARK: - Where a picture comes from

    func testAServersDeclaredIconsComeFirstThenTheDirectorysAndNeverAnotherSites() throws {
        let linear = try XCTUnwrap(ConnectorPreset.preset(id: "linear"))
        let icons = [
            MCPServerIcon(src: "https://mcp.linear.app/icon-48.png", sizes: ["48x48"]),
            MCPServerIcon(src: "https://linear.app/icon-512.png", sizes: ["512x512"]),
            MCPServerIcon(src: "https://linear.app/icon-dark.svg", sizes: ["any"], theme: "dark"),
            MCPServerIcon(src: "https://favicons.third-party.test/linear.png", sizes: ["1024x1024"]),
            MCPServerIcon(src: "http://linear.app/plain-http.png", sizes: ["1024x1024"]),
            MCPServerIcon(src: "data:image/png;base64,AAAA", sizes: ["16x16"], theme: "light")
        ]
        let sources = ConnectorIconSources.make(serverURL: linear.serverURL, serverIcons: icons, preset: linear)
        XCTAssertEqual(sources.light.map(\.absoluteString), [
            "data:image/png;base64,AAAA", "https://linear.app/icon-512.png", "https://linear.app/icon-dark.svg",
            "https://linear.app/static/apple-touch-icon.png"
        ], "The light icon, the largest for either theme, the dark one, then the directory's; no other site, no http")
        XCTAssertEqual(sources.dark.first?.absoluteString, "https://linear.app/icon-dark.svg")
        XCTAssertEqual(sources.dark.last, linear.iconURL)
    }

    func testWithoutDeclaredIconsTheDirectorysIconAloneAndNoneForAServiceItDoesNotKnow() throws {
        XCTAssertEqual(ConnectorIconSources.preset("notion").light.map(\.absoluteString),
                       ["https://www.notion.com/front-static/logo-ios.png"])
        XCTAssertEqual(ConnectorIconSources.preset("gmail").light.first?.host(), "www.gstatic.com", "Google's own static host")
        XCTAssertTrue(ConnectorIconSources.preset("monday").isEmpty, "Only a 16 px icon: the symbol stays")
        XCTAssertTrue(ConnectorIconSources.preset(nil).isEmpty)
        let custom = ConnectorRecord(name: "docs", slug: "docs", serverURL: URL(string: "https://docs.example.test/mcp")!)
        XCTAssertTrue(custom.iconSources.isEmpty)
    }

    func testEveryDirectoryIconIsHTTPSOnTheServicesOwnSite() throws {
        for preset in ConnectorPreset.all {
            guard let url = preset.iconURL else { continue }
            // The Mac's own apps draw the icon macOS gives them, from no site at all.
            if preset.localService.map({ $0.isMac || $0 == .xcode }) == true {
                XCTAssertTrue(url.isFileURL && url.pathExtension == "app", preset.id)
                continue
            }
            XCTAssertEqual(url.scheme, "https", preset.id)
            let site = ConnectorIconSite.baseDomain(try XCTUnwrap(url.host(), preset.id))
            XCTAssertFalse(["duckduckgo.com", "icon.horse", "clearbit.com", "faviconkit.com"].contains(site),
                           "\(preset.id): a favicon service")
            if ["google.com", "gstatic.com"].contains(site) {
                XCTAssertNotNil(preset.localService, "\(preset.id): only Google's own services use Google's hosts")
            }
        }
        XCTAssertGreaterThanOrEqual(ConnectorPreset.all.filter { $0.iconURL != nil }.count, 40)
        XCTAssertEqual(Set(ConnectorPreset.iconAddresses.keys).subtracting(ConnectorPreset.all.map(\.id)), [],
                       "Every icon belongs to a directory entry")
    }

    func testBaseDomain() {
        XCTAssertEqual(ConnectorIconSite.baseDomain("mcp.linear.app"), "linear.app")
        XCTAssertEqual(ConnectorIconSite.baseDomain("linear.app"), "linear.app")
        XCTAssertEqual(ConnectorIconSite.baseDomain("static.example.co.uk"), "example.co.uk")
        XCTAssertEqual(ConnectorIconSite.baseDomain("a.b.example.com"), "example.com")
    }

    func testServerInfoIconsAreRead() {
        let info: ToolJSON = .object(["name": .string("x"), "icons": .array([
            .object(["src": .string("https://x.test/a.png"), "sizes": .array([.string("32x32"), .string("64x64")])]),
            .object(["src": .string("  ")]),
            .object(["src": .string("https://x.test/b.svg"), "sizes": .string("any"), "theme": .string("dark")])
        ])])
        let icons = MCPServerIcon.list(in: info)
        XCTAssertEqual(icons.map(\.src), ["https://x.test/a.png", "https://x.test/b.svg"])
        XCTAssertEqual(icons.first?.area, 64 * 64)
        XCTAssertEqual(icons.last?.area, .infinity)
        XCTAssertEqual(icons.last?.theme, "dark")
    }

    /// Connecting keeps what the server said about itself, and the record's picture comes from it.
    func testConnectingKeepsTheServersIcons() async throws {
        let server = FakeConnectorServer(requiresToken: false)
        let repository = InMemoryConnectorRepository()
        let center = ConnectorCenter(environment: ConnectorCenter.Environment(
            repository: repository, credentials: InMemoryConnectorCredentialStore(), http: server,
            userAgent: FakeUserAgent(), sha256: MacOAuthUserAgent.sha256, clientVersion: "9.9"))
        let record = try await center.add(name: "Example", serverURL: FakeConnectorServer.mcpURL)
        center.connect(record.id)
        await center.waitForConnection(record.id)
        let connected = try XCTUnwrap(center.record(record.id))
        XCTAssertEqual(connected.status, .connected)
        XCTAssertEqual(connected.serverIcons?.count, 3)
        XCTAssertEqual(connected.iconSources.light.map(\.absoluteString),
                       ["https://mcp.example.test/icon-64.png", "https://example.test/icon-dark.svg"],
                       "The other site's 512 px icon is left out")
        XCTAssertEqual(repository.records.first?.serverIcons, connected.serverIcons, "Saved with the connector")
    }

    func testARecordFromBeforeIconsStillReads() throws {
        let old = #"{"id":"6C3C9E52-2B66-4C66-9B07-6A31D4F8E3A1","name":"Linear","slug":"linear","serverURL":"https:\/\/mcp.linear.app\/mcp","authorization":"oauth","status":"connected","tools":[],"presetID":"linear"}"#
        let record = try JSONDecoder().decode(ConnectorRecord.self, from: Data(old.utf8))
        XCTAssertNil(record.serverIcons)
        XCTAssertEqual(record.iconSources.light, [try XCTUnwrap(ConnectorPreset.preset(id: "linear")?.iconURL)])
    }

    // MARK: - The store

    private final class Fetches: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        var answer: Result<Data, Error>
        init(_ answer: Result<Data, Error>) { self.answer = answer }
        var count: Int { lock.withLock { urls.count } }
        func fetch(_ url: URL) throws -> Data {
            try lock.withLock {
                urls.append(url)
                return try answer.get()
            }
        }
    }

    private static func png(size: Int = 32) -> Data {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor.systemPurple.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            return true
        }
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }

    func testAPictureIsFetchedOnceAndThenReadFromDisk() async throws {
        let directory = try temporaryDirectory()
        let fetches = Fetches(.success(Self.png()))
        let environment = ConnectorIconStoreEnvironment(fetch: { try fetches.fetch($0) }, directory: directory, now: { Date() })
        let url = URL(string: "https://linear.app/static/apple-touch-icon.png")!
        let first = ConnectorIconStore(environment: environment)
        let image = await first.image(for: [url])
        XCTAssertNotNil(image)
        XCTAssertNotNil(first.cachedImage(for: [url]))
        _ = await first.image(for: [url])
        XCTAssertEqual(fetches.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: ConnectorIconStore.fileName(for: url)).path))

        let later = ConnectorIconStore(environment: environment)
        let result1 = await later.image(for: [url])
        XCTAssertNotNil(result1, "Read from disk")
        XCTAssertEqual(fetches.count, 1)
    }

    func testAMissIsNotAskedForAgainForADayAndTheNextSourceIsTried() async throws {
        let directory = try temporaryDirectory()
        let fetches = Fetches(.failure(URLError(.badServerResponse)))
        let clock = Clock()
        let environment = ConnectorIconStoreEnvironment(fetch: { try fetches.fetch($0) }, directory: directory, now: { clock.now })
        let broken = URL(string: "https://broken.example.test/icon.png")!
        let pngData = Self.png()
        let inline = URL(string: "data:image/png;base64," + pngData.base64EncodedString())!

        let store = ConnectorIconStore(environment: environment)
        let result2 = await store.image(for: [broken, inline])
        XCTAssertNotNil(result2, "The data URL after the miss")
        XCTAssertEqual(fetches.count, 1)
        let result3 = await ConnectorIconStore(environment: environment).image(for: [broken])
        XCTAssertNil(result3)
        XCTAssertEqual(fetches.count, 1, "Within a day the miss stands, across launches")
        clock.now = clock.now.addingTimeInterval(ConnectorIconStore.retryAfter + 60)
        _ = await ConnectorIconStore(environment: environment).image(for: [broken])
        XCTAssertEqual(fetches.count, 2, "A day on it is asked for again")
    }

    func testWhatIsNotAPictureOrIsTooLargeIsNotTaken() async throws {
        let html = Fetches(.success(Data("<!doctype html><title>Not found</title>".utf8)))
        let store = ConnectorIconStore(environment: ConnectorIconStoreEnvironment(fetch: { try html.fetch($0) }, directory: nil, now: { Date() }))
        let result4 = await store.image(for: [URL(string: "https://example.test/apple-touch-icon.png")!])
        XCTAssertNil(result4)
        let large = Fetches(.success(Self.png() + Data(count: ConnectorIconStore.maximumBytes)))
        let big = ConnectorIconStore(environment: ConnectorIconStoreEnvironment(fetch: { try large.fetch($0) }, directory: nil, now: { Date() }))
        let result5 = await big.image(for: [URL(string: "https://example.test/huge.png")!])
        XCTAssertNil(result5)
    }

    func testTheAppsStoreNeverFetchesInATestProcess() async throws {
        let url = try XCTUnwrap(ConnectorPreset.preset(id: "notion")?.iconURL)
        let image = await ConnectorIconStore.shared.image(for: [url])
        XCTAssertNil(image)
        XCTAssertEqual(ConnectorIconStore.decodeDataURL(URL(string: "data:image/svg+xml,%3Csvg%2F%3E")!), Data("<svg/>".utf8))
    }

    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    // MARK: - Live, opt-in

    func testLiveDirectoryIconsDraw() async throws {
        guard ProcessInfo.processInfo.environment["YARDLET_CONNECTOR_ICONS_LIVE"] == "1" else {
            throw XCTSkip("Set YARDLET_CONNECTOR_ICONS_LIVE=1 to fetch the directory's icons from each service's own site")
        }
        let cache = try temporaryDirectory()
        let store = ConnectorIconStore(environment: ConnectorIconStoreEnvironment(
            fetch: { try await ConnectorIconStore.download($0) }, directory: cache, now: { Date() }))
        var loaded: [String] = [], missed: [String] = []
        for preset in ConnectorPreset.all {
            let sources = ConnectorIconSources.preset(preset.id)
            guard !sources.isEmpty else { continue }
            if await store.image(for: sources.light) != nil { loaded.append(preset.id) } else { missed.append(preset.id) }
        }
        _ = await store.image(for: ConnectorIconSources.google.light)
        print("Connector icons loaded: \(loaded.count), missed: \(missed)")
        XCTAssertGreaterThanOrEqual(loaded.count, 38, "missed: \(missed)")

        let directory = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: ".build/ui-polish-qa/after/live-icons", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let center = ConnectorCenter(environment: ConnectorCenter.Environment(
            repository: InMemoryConnectorRepository(records: ConnectorsRenderingTests.records),
            credentials: InMemoryConnectorCredentialStore(), http: FakeConnectorServer(), userAgent: FakeUserAgent(),
            sha256: MacOAuthUserAgent.sha256, clientVersion: "9.9"))

        let settings = NSSize(width: 820, height: 1000)
        _ = try WindowlessRender.hostedInBothAppearances("settings-connectors", in: directory, size: settings, passes: 12) { appearance in
            SettingsCenterView(size: CGSize(width: settings.width, height: settings.height),
                               initialSection: SettingsSection.connectors.rawValue,
                               notificationCenter: MenuBarQuietNotificationCenter(), connectors: center)
                .environment(\.connectorIconStore, store)
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: settings.width, height: settings.height)
        }
        let sheet = NSSize(width: 580, height: 900)
        _ = try WindowlessRender.hostedInBothAppearances("add-directory", in: directory, size: sheet, passes: 12) { appearance in
            ConnectorAddSheet(center: center, start: .directory, onClose: {})
                .environment(\.connectorIconStore, store)
                .environment(\.colorScheme, appearance.colorScheme)
        }
        let states: [String: ConnectorTaskState] = ["Notion": .off]
        let list = try XCTUnwrap(ComposerConnectorList.make(
            ComposerConnectorsSlot(sessionServers: [
                HarnessMCPServerStatus(name: "yardlet", state: .connected, toolCount: 120),
                HarnessMCPServerStatus(name: "linear", state: .connected, toolCount: 23)
            ], carriesYardletConnectors: true),
            connectors: ConnectorsRenderingTests.records, taskState: { states[$0.name] ?? .on }))
        let menu = NSSize(width: 360, height: 520)
        _ = try WindowlessRender.hostedInBothAppearances("composer-connectors", in: directory, size: menu, passes: 12) { appearance in
            ComposerConnectorsMenu(list: list, onManage: {}, onSwitch: { _, _ in }, onReconnect: { _ in })
                .background(ParityTheme.elevated, in: RoundedRectangle(cornerRadius: 10))
                .padding(12)
                .environment(\.connectorIconStore, store)
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: menu.width, height: menu.height, alignment: .topLeading)
                .background(ParityTheme.canvas)
        }
    }
}
