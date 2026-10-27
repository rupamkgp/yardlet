import AppKit
import SwiftUI

/// Connector pictures fetched from each service's own site or MCP server (`ConnectorIconSources`),
/// kept in memory and in `~/Library/Caches/<bundle>/ConnectorIcons` so each is asked for once. A
/// picture that does not load is not asked for again for a day; the symbol stands in meanwhile.
/// The request carries no cookies or credentials.
@MainActor
final class ConnectorIconStore {
    typealias Environment = ConnectorIconStoreEnvironment

    /// The app's store. A test process never reaches the network through it.
    nonisolated static let shared = ConnectorIconStore(environment: .live)

    /// How long a picture that did not load waits before it is asked for again.
    static let retryAfter: TimeInterval = 24 * 60 * 60
    /// The largest picture taken.
    static let maximumBytes = 1_000_000

    private let environment: Environment
    private var images: [URL: NSImage]
    private var missed: Set<URL>
    private var loads: [URL: Task<NSImage?, Never>]

    nonisolated init(environment: Environment) {
        self.environment = environment
        images = [:]
        missed = []
        loads = [:]
    }

    /// The first of `urls` already in memory.
    func cachedImage(for urls: [URL]) -> NSImage? {
        urls.lazy.compactMap { self.images[$0] }.first
    }

    /// The first of `urls` that gives a picture, from memory, disk, or the network in turn.
    func image(for urls: [URL]) async -> NSImage? {
        if let cached = cachedImage(for: urls) { return cached }
        for url in urls {
            if let image = await load(url) { return image }
        }
        return nil
    }

    /// Puts a picture in memory, as a test's fixture does.
    func insert(_ image: NSImage, for url: URL) {
        images[url] = image
    }

    private func load(_ url: URL) async -> NSImage? {
        if let image = images[url] { return image }
        guard !missed.contains(url) else { return nil }
        if let running = loads[url] { return await running.value }
        let task = Task { await self.fetch(url) }
        loads[url] = task
        let image = await task.value
        loads[url] = nil
        if let image { images[url] = image } else { missed.insert(url) }
        return image
    }

    private func fetch(_ url: URL) async -> NSImage? {
        if url.scheme?.lowercased() == "data" { return Self.decodeDataURL(url).flatMap(Self.picture) }
        let file = environment.directory?.appending(path: Self.fileName(for: url))
        let miss = file?.appendingPathExtension("miss")
        if let file, let data = try? Data(contentsOf: file), let image = Self.picture(data) { return image }
        if let miss, let date = (try? miss.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           environment.now().timeIntervalSince(date) < Self.retryAfter {
            return nil
        }
        let data = try? await environment.fetch(url)
        guard let data, data.count <= Self.maximumBytes, let image = Self.picture(data) else {
            if let miss, let directory = environment.directory {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? Data().write(to: miss)
                // Dated by the store's clock, which the next look compares with.
                try? FileManager.default.setAttributes([.modificationDate: environment.now()], ofItemAtPath: miss.path)
            }
            return nil
        }
        if let file, let directory = environment.directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            if let miss { try? FileManager.default.removeItem(at: miss) }
        }
        return image
    }

    /// A picture with a size: PNG, ICO, SVG, JPEG, and what else `NSImage` reads.
    private static func picture(_ data: Data) -> NSImage? {
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        return image
    }

    /// `data:image/png;base64,…` and its percent-encoded form.
    static func decodeDataURL(_ url: URL) -> Data? {
        let text = url.absoluteString
        guard let comma = text.firstIndex(of: ","), text.lowercased().hasPrefix("data:image/") else { return nil }
        let header = text[..<comma].lowercased()
        let payload = String(text[text.index(after: comma)...])
        if header.hasSuffix(";base64") { return Data(base64Encoded: payload.removingPercentEncoding ?? payload) }
        return payload.removingPercentEncoding.map { Data($0.utf8) }
    }

    /// A stable file name for an address (FNV-1a, 64 bits).
    static func fileName(for url: URL) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in url.absoluteString.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    /// One GET with no cookies, cache, or credentials, following the site's redirects.
    @Sendable
    nonisolated static func download(_ url: URL) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else { throw URLError(.unsupportedURL) }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("image/avif,image/webp,image/png,image/svg+xml,image/*;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.url?.scheme?.lowercased() == "https" else { throw URLError(.badServerResponse) }
        return data
    }

    private nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()
}

/// Where a `ConnectorIconStore` fetches from and keeps its pictures.
nonisolated struct ConnectorIconStoreEnvironment: Sendable {
    var fetch: @Sendable (URL) async throws -> Data
    /// Where pictures are kept between runs; nil keeps them in memory only.
    var directory: URL?
    var now: @Sendable () -> Date

    static var live: ConnectorIconStoreEnvironment {
        // XCTest is loaded: `swift test` is running, which never fetches.
        guard NSClassFromString("XCTestCase") == nil else {
            return ConnectorIconStoreEnvironment(fetch: { _ in throw URLError(.notConnectedToInternet) }, directory: nil, now: { Date() })
        }
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: Bundle.main.bundleIdentifier ?? "com.zzunkie.yardlet", directoryHint: .isDirectory)
            .appending(path: "ConnectorIcons", directoryHint: .isDirectory)
        return ConnectorIconStoreEnvironment(fetch: { try await ConnectorIconStore.download($0) }, directory: directory, now: { Date() })
    }
}

private struct ConnectorIconStoreKey: EnvironmentKey {
    nonisolated static let defaultValue: ConnectorIconStore = .shared
}

extension EnvironmentValues {
    /// Where connector pictures come from: the app's store, or a test's.
    var connectorIconStore: ConnectorIconStore {
        get { self[ConnectorIconStoreKey.self] }
        set { self[ConnectorIconStoreKey.self] = newValue }
    }
}
