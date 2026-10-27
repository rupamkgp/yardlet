#if DEBUG
import AppKit
import Foundation

/// QA for each task's own browser profile against the real browser host (docs/BROWSER_SESSION_ISOLATION.md),
/// run by `run-check.sh … --ui-fixture-browser-check-only=isolation` in a temporary home, which may hold an
/// earlier QA run's browser data: each check uses new tasks and sets what it reads. Made-up cookies on the
/// QA server only. Phase markers let run-check.sh sample the process tree's memory as contexts are added.
/// Checks land in `result.json`.
@MainActor
final class BrowserHostIsolationQA {
    private let output: URL
    private let base: String
    private var record: [String: JSONValue] = [:]
    private var checks: [JSONValue] = []
    private var client: BrowserHostClient { MacBrowserHost.shared.client }
    private var profiles: BrowserTaskProfiles { MacBrowserHost.shared.profiles }
    private static let passkeyKey = "qa-metadata-key-not-real"

    init(output: URL, base: String) {
        self.output = output
        self.base = base.replacingOccurrences(of: "127.0.0.1", with: "localhost")
    }

    func run() async {
        try? FileManager.default.createDirectory(at: output.appending(path: "markers"), withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(3))
        let page = base + "isolation"
        // The default profile before the host opens it: a Touch ID metadata key a new task profile must carry.
        let defaultPreferences = MacBrowserHost.shared.paths.profile.appending(path: "Preferences")
        try? FileManager.default.createDirectory(at: MacBrowserHost.shared.paths.profile, withIntermediateDirectories: true)
        var preferences = (try? Data(contentsOf: defaultPreferences))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var webauthn = preferences["webauthn"] as? [String: Any] ?? [:]
        webauthn["touchid"] = ["metadata_secret": Self.passkeyKey]
        preferences["webauthn"] = webauthn
        try? JSONSerialization.data(withJSONObject: preferences).write(to: defaultPreferences)
        // `--ui-fixture-isolation-cookies` runs only the check that copied cookies stay as Chromium stored them.
        if CommandLine.arguments.contains("--ui-fixture-isolation-cookies") {
            record["storage"] = .string(profiles.storage.rawValue)
            await copiesCookiesAsStored()
            return await finish()
        }
        // `--ui-fixture-isolation-shared` measures the same tabs in the one default profile, for comparison.
        if CommandLine.arguments.contains("--ui-fixture-isolation-shared") {
            profiles.storage = .shared
            record["storage"] = .string(profiles.storage.rawValue)
            _ = try? client.openTab(url: page, viewport: .offscreenDefault)
            try? await Task.sleep(for: .seconds(2))
            await phase("iso-0-default")
            for name in ["iso-4-shared", "iso-8-shared"] {
                for _ in 0..<4 { _ = await taskTab(UUID(), page) }
                await phase(name)
            }
            profiles.storage = .perTask
            return await finish()
        }
        record["storage"] = .string(profiles.storage.rawValue)

        // A tab of no task is in the default profile: a cookie there is what new tasks start with.
        guard let baseline = try? client.openTab(url: page, viewport: .offscreenDefault), await loaded(baseline, page) else {
            check("the default profile's page loads", false, "no tab")
            return await finish()
        }
        _ = await value(baseline, "document.cookie = 'baseline=1; path=/; max-age=3600'; document.cookie = 'who=; path=/; max-age=0'; 1")
        await phase("iso-0-default")

        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        guard let tabA = await taskTab(a, page), let tabB = await taskTab(b, page) else { return await finish() }
        let startA = await cookies(tabA), startB = await cookies(tabB)
        check("a new task starts with the default profile's cookies", startA.contains("baseline=1") && startB.contains("baseline=1"),
              "A \(startA) / B \(startB)")
        _ = await value(tabA, "document.cookie = 'who=A; path=/; max-age=3600'; localStorage.setItem('who', 'A'); 1")
        _ = await value(tabB, "document.cookie = 'who=B; path=/; max-age=3600'; localStorage.setItem('who', 'B'); 1")
        let cookieA = await cookies(tabA), cookieB = await cookies(tabB)
        let storeA = await value(tabA, "localStorage.getItem('who')"), storeB = await value(tabB, "localStorage.getItem('who')")
        check("two tasks signed in to the same site keep their own cookies and local storage",
              cookieA.contains("who=A") && !cookieA.contains("who=B") && cookieB.contains("who=B") && !cookieB.contains("who=A")
                && storeA == .string("A") && storeB == .string("B"),
              "A \(cookieA) \(String(describing: storeA)) / B \(cookieB) \(String(describing: storeB))")
        let baselineAfter = await cookies(baseline)
        check("a task's sign-in stays out of the default profile", !baselineAfter.contains("who="), baselineAfter)

        // A child task starts signed in as its parent.
        profiles.parentOf = { $0 == c ? a : nil }
        guard let tabC = await taskTab(c, page) else { return await finish() }
        let cookieC = await cookies(tabC)
        check("a child task starts with its parent task's cookies", cookieC.contains("who=A"), cookieC)

        // The person signed in on task B's page: that site's cookies go to the default profile; a task started
        // after that begins with them, and task A keeps its own.
        client.copyCookies(fromSession: b, toDefaultFor: "localhost")
        try? await Task.sleep(for: .seconds(2))
        guard let tabD = await taskTab(d, page) else { return await finish() }
        let cookieD = await cookies(tabD), stillA = await cookies(tabA)
        check("a person's sign-in reaches the default profile and the tasks started after it, not the running ones",
              cookieD.contains("who=B") && stillA.contains("who=A") && !stillA.contains("who=B"), "D \(cookieD) / A \(stillA)")

        let taskPreferences = (try? Data(contentsOf: profiles.folder(for: profiles.key(for: a)).appending(path: "Preferences")))
            .flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        let copiedKey = taskPreferences?["webauthn"]?["touchid"]?["metadata_secret"]?.stringValue
        check("a task profile carries the default profile's Touch ID passkey key", copiedKey == Self.passkeyKey,
              copiedKey == nil ? "missing" : "present")
        await phase("iso-4-contexts")

        // Memory: four more tasks, then eight tabs of one task for comparison.
        var more: [UUID] = []
        for _ in 0..<4 {
            let task = UUID()
            more.append(task)
            _ = await taskTab(task, page)
        }
        await phase("iso-8-contexts")

        // The host ends when no tab is left: a task's sign-in, session cookies too, and its local storage
        // are on disk when its tab opens again, and the folder is not seeded again.
        _ = await value(tabA, "document.cookie = 'visit=A; path=/'; 1")
        for task in [a, b, c, d] + more { client.closeTabs(forSession: task) }
        baseline.close()
        client.terminateHost()
        _ = await waitUntil(.seconds(20)) { !self.client.isHostRunning }
        try? await Task.sleep(for: .seconds(1))
        if let againA = await taskTab(a, page) {
            let cookie = await cookies(againA), store = await value(againA, "localStorage.getItem('who')")
            check("a task's profile keeps its cookies and local storage across host restarts",
                  cookie.contains("who=A") && cookie.contains("visit=A") && !cookie.contains("who=B") && store == .string("A"),
                  "A \(cookie) \(String(describing: store))")
        }

        // Shared storage: a tab opens in the default profile again.
        profiles.storage = .shared
        let shared = UUID()
        if let tabShared = await taskTab(shared, page) {
            let sharedCookies = await cookies(tabShared)
            check("with shared storage a task's tab uses the default profile", sharedCookies.contains("baseline=1")
                  && sharedCookies.contains("who=B") && !profiles.folderExists(shared.uuidString), sharedCookies)
        }
        profiles.storage = .perTask

        await copiesCookiesAsStored()

        // Archived and deleted tasks' profiles go once the host has let them go.
        for task in [a, shared] { client.closeTabs(forSession: task) }
        client.terminateHost()
        _ = await waitUntil(.seconds(20)) { !self.client.isHostRunning }
        try? await Task.sleep(for: .seconds(1))
        let removed = Set(profiles.removeFolders(keeping: [a]))
        let unkept = Set(([b, c, d] + more).map(\.uuidString))
        // Chromium's own list of the profiles it opened forgets the removed ones too.
        let localState = (try? Data(contentsOf: MacBrowserHost.shared.paths.root.appending(path: "Local State")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let listed = Set(((localState?["profile"] as? [String: Any])?["info_cache"] as? [String: Any])?.keys.map { $0 } ?? [])
        let listedUnkept = unkept.filter { listed.contains(BrowserTaskProfiles.folderPrefix + $0) }
        check("removing unkept profiles keeps the kept task's folder and removes the rest, from Chromium's profile list too",
              profiles.folderExists(profiles.key(for: a)) && unkept.isSubset(of: removed) && !unkept.contains(where: profiles.folderExists)
                && listed.contains(BrowserTaskProfiles.folderPrefix + profiles.key(for: a)) && listedUnkept.isEmpty,
              "removed \(removed.count), this run's \(unkept.intersection(removed).count) of \(unkept.count); "
                + "Local State lists \(listed.count), removed ones still listed \(listedUnkept.count)")
        await finish()
    }

    // MARK: Cookies copied as stored

    /// A new task's starting cookies, and the person's sign-in copied back, must be the cookies Chromium stored.
    /// Google's accounts site answers a missing __Host- cookie, or a sign-in cookie that comes twice, with
    /// /CookieMismatch, as the Google Cloud console did in Yardlet's tasks until 2026-10-25
    /// (docs/BROWSER_SESSION_ISOLATION.md 8). Two parts: the QA server's sign-in check across two sites
    /// (`/cookie-check`, console 127.0.0.1 and accounts localhost), and Google-shaped cookies on a registrable
    /// domain set through DevTools and read back the same way (example.com is never loaded), since Chromium keeps a
    /// localhost cookie host-only whatever domain it is given.
    private func copiesCookiesAsStored() async {
        let console = base.replacingOccurrences(of: "localhost", with: "127.0.0.1")
        guard let home = try? client.openTab(url: console + "cookie-check/start", viewport: .offscreenDefault),
              await waitUntil(.seconds(20), { home.currentURL?.contains("/cookie-check/verify") == true && !home.isLoading }),
              let verify = home.currentURL else {
            check("cookie check: the default profile signs in across two sites", false, "no verify page")
            return
        }
        let signedIn = await value(home, "window.qa.cookieCheck")
        record["cookieCheckAgent"] = .object(["userAgent": signedIn?["userAgent"] ?? .null,
                                              "secChUa": signedIn?["secChUa"] ?? .null,
                                              "secChUaPlatform": signedIn?["secChUaPlatform"] ?? .null])
        check("cookie check: the default profile signs in across two sites", signedIn?["status"]?.stringValue == "ok",
              Self.describe(signedIn))
        // The accounts site in a frame of the console: a partitioned cookie and an unpartitioned third-party one.
        if let framed = try? client.openTab(url: console + "cookie-check/console", viewport: .offscreenDefault) {
            _ = await waitUntil(.seconds(10)) { !framed.isLoading && framed.currentURL?.contains("/cookie-check/console") == true }
            var frame: JSONValue?
            for _ in 0..<50 where frame == nil {
                frame = await value(framed, "window.qa.frame")
                if frame == nil { try? await Task.sleep(for: .milliseconds(200)) }
            }
            record["cookieCheckFrame"] = frame ?? .null
            framed.close()
        }
        let e = UUID()
        if let tabE = await taskTab(e, verify) {
            let copied = await value(tabE, "window.qa.cookieCheck")
            check("cookie check: a new task signs in across two sites with the cookies it started with",
                  copied?["status"]?.stringValue == "ok", Self.describe(copied))
        }

        // Google-shaped cookies on a registrable domain in the default profile: host-only sign-in cookies on the
        // accounts host (one __Host-), a Secure domain cookie and a non-Secure one (set over HTTP: DevTools makes a
        // cookie it sets over HTTPS Secure), and a cookie partitioned under another top-level site.
        let accounts = "https://accounts.example.com/"
        let expires = JSONValue.number(Date().timeIntervalSince1970 + 3600)
        func cookie(_ name: String, _ value: String, url: String = accounts, domain: String? = nil, secure: Bool = true,
                    partitionedUnder site: String? = nil) -> JSONValue {
            // SameSite=None needs Secure, so a non-Secure cookie is Lax.
            var fields: [String: JSONValue] = ["name": .string(name), "value": .string(value), "url": .string(url),
                                               "path": .string("/"), "secure": .bool(secure), "httpOnly": .bool(true),
                                               "sameSite": .string(secure ? "None" : "Lax"), "expires": expires]
            if let domain { fields["domain"] = .string(domain) }
            if let site { fields["partitionKey"] = .object(["topLevelSite": .string(site), "hasCrossSiteAncestor": .bool(false)]) }
            return .object(fields)
        }
        let signIn = ["qa_signin", "__Host-qa_signin"]
        // An earlier run's cookies in this QA home go first: DevTools deletes a cookie of the exact domain given.
        let partition = JSONValue.object(["topLevelSite": .string("https://example.org"), "hasCrossSiteAncestor": .bool(false)])
        for name in signIn + ["qa_session", "qa_plain", "qa_partitioned", "qa_probe"] {
            for domain in ["accounts.example.com", ".accounts.example.com", ".example.com", "widget.example.net",
                           ".widget.example.net", "probe.test"] {
                _ = try? await home.devTools.send("Network.deleteCookies", ["name": .string(name), "domain": .string(domain)])
                if name == "qa_partitioned" {
                    _ = try? await home.devTools.send("Network.deleteCookies", [
                        "name": .string(name), "domain": .string(domain), "partitionKey": partition
                    ])
                }
            }
        }
        _ = try? await home.devTools.send("Network.setCookies", ["cookies": .array([
            cookie("qa_signin", "A"), cookie("__Host-qa_signin", "A"),
            cookie("qa_session", "A", domain: ".example.com"),
            cookie("qa_plain", "A", url: "http://accounts.example.com/", domain: ".example.com", secure: false),
            cookie("qa_partitioned", "A", url: "https://widget.example.net/", partitionedUnder: "https://example.org")
        ])])
        let planted = await storedCookies(home)
        // Whether Chromium binds a cookie to the scheme that set it: a non-Secure cookie set over HTTP, asked for
        // over HTTPS. The copy sets a non-Secure cookie over HTTP, since CEF does not say which scheme set it.
        _ = try? await home.devTools.send("Network.setCookie", [
            "name": .string("qa_probe"), "value": .string("1"), "url": .string("http://probe.test/"), "path": .string("/"),
            "sourceScheme": .string("NonSecure"), "sourcePort": .integer(80), "expires": expires
        ])
        record["schemeBoundCookies"] = .bool(await sentCookies(home, "https://probe.test/")["qa_probe"] == nil)
        let f = UUID()
        guard let tabF = await taskTab(f, base + "isolation") else { return }
        let started = await storedCookies(tabF)
        let sent = await sentCookies(tabF, accounts)
        // CEF's cookie manager cannot set a partitioned cookie: a copy leaves it out rather than make it a cookie of
        // every top-level site. Nor does it say which scheme and port set a cookie (`from=`, recorded only).
        let kept = { (cookies: [String]) in
            cookies.filter { $0.contains(" partition=- ") }
                .map { $0.replacingOccurrences(of: #" from=\S+"#, with: "", options: .regularExpression) }
        }
        record["cookiesCopied"] = .object(["default": .array(planted.map(JSONValue.string)),
                                           "task": .array(started.map(JSONValue.string))])
        check("cookies: a new task starts with each cookie as the default profile stores it",
              planted.count == 5 && kept(started) == kept(planted)
                && !started.contains { $0.hasPrefix("qa_partitioned ") && $0.contains(" partition=- ") }
                && signIn.allSatisfy { sent[$0]?.count == 1 },
              "task \(started) / accounts.example.com gets \(sent)")

        // The person signs in again on task F's page: new host-only sign-in cookies there, copied to the default
        // profile for the site. The accounts site must then get one of each from the default profile and from a
        // task started after it, the new one.
        // Both profiles also hold the domain cookie the copy before 2026-10-25 made of the sign-in cookie, as the
        // person's profiles did on 2026-10-26: the copy carries the site's host-only cookie and leaves neither
        // domain cookie, or the accounts site gets two values (Google's /CookieMismatch).
        let legacy = JSONValue.array([cookie("qa_signin", "OLD", domain: ".accounts.example.com")])
        _ = try? await home.devTools.send("Network.setCookies", ["cookies": legacy])
        _ = try? await tabF.devTools.send("Network.setCookies", ["cookies": legacy])
        _ = try? await tabF.devTools.send("Network.setCookies", ["cookies": .array([
            cookie("qa_signin", "B"), cookie("__Host-qa_signin", "B")
        ])])
        client.copyCookies(fromSession: f, toDefaultFor: "example.com")
        try? await Task.sleep(for: .seconds(2))
        let g = UUID()
        let fromDefault = await sentCookies(home, accounts)
        var fromG: [String: [String]] = [:]
        if let tabG = await taskTab(g, base + "isolation") { fromG = await sentCookies(tabG, accounts) }
        check("cookies: a person's sign-in copied to the default profile replaces its sign-in cookies and the copied domain cookie beside them, in later tasks too",
              signIn.allSatisfy { fromDefault[$0] == ["B"] && fromG[$0] == ["B"] },
              "default \(fromDefault) / later task \(fromG)")
        for task in [e, f, g] { client.closeTabs(forSession: task) }
        home.close()
    }

    /// The cookies this check plants, in a tab's profile as Chromium stores them: name, domain (a leading dot for a
    /// domain cookie), Secure, the site it is partitioned under, the scheme and port that set it, and the value.
    private func storedCookies(_ tab: BrowserTab) async -> [String] {
        let planted: Set = ["qa_signin", "__Host-qa_signin", "qa_session", "qa_plain", "qa_partitioned"]
        let all = try? await tab.devTools.send("Network.getAllCookies", [:], timeout: .seconds(10))
        return (all?["cookies"]?.arrayValue ?? []).compactMap { cookie -> String? in
            guard let name = cookie["name"]?.stringValue, planted.contains(name),
                  cookie["domain"]?.stringValue?.contains("example.") == true else { return nil }
            let partition = cookie["partitionKey"]?["topLevelSite"]?.stringValue ?? "-"
            let port = cookie["sourcePort"].map { Self.describe($0) } ?? "?"
            return "\(name) \(cookie["domain"]?.stringValue ?? "?") \(cookie["secure"]?.boolValue == true ? "Secure" : "-") "
                + "partition=\(partition) from=\(cookie["sourceScheme"]?.stringValue ?? "?"):\(port) "
                + "value=\(cookie["value"]?.stringValue ?? "?")"
        }.sorted()
    }

    /// The values of each QA cookie Chromium would send to `url`, as a site's server reads its Cookie header.
    private func sentCookies(_ tab: BrowserTab, _ url: String) async -> [String: [String]] {
        let list = try? await tab.devTools.send("Network.getCookies", ["urls": .array([.string(url)])], timeout: .seconds(10))
        var sent: [String: [String]] = [:]
        for cookie in list?["cookies"]?.arrayValue ?? [] {
            guard let name = cookie["name"]?.stringValue, name.contains("qa_") else { continue }
            sent[name, default: []].append(cookie["value"]?.stringValue ?? "?")
        }
        return sent
    }

    private static func describe(_ value: JSONValue?) -> String {
        guard let value, let data = try? JSONEncoder().encode(value) else { return "none" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Pieces

    private func taskTab(_ session: UUID, _ url: String) async -> BrowserTab? {
        guard let tab = try? client.openTab(forSession: session, url: url, viewport: .offscreenDefault), await loaded(tab, url) else {
            check("a task's tab loads (\(session.uuidString.prefix(8)))", false, "not loaded")
            return nil
        }
        return tab
    }

    /// Waits for the page: a new task's tab first takes its starting cookies on about:blank.
    private func loaded(_ tab: BrowserTab, _ url: String) async -> Bool {
        await waitUntil(.seconds(20)) { tab.currentURL == url && !tab.isLoading }
    }

    private func value(_ tab: BrowserTab, _ expression: String) async -> JSONValue? {
        let result = try? await tab.devTools.send("Runtime.evaluate", [
            "expression": .string(expression), "returnByValue": .bool(true)
        ], timeout: .seconds(10))
        return result?["result"]?["value"]
    }

    private func cookies(_ tab: BrowserTab) async -> String {
        await value(tab, "document.cookie")?.stringValue ?? ""
    }

    private func phase(_ name: String) async {
        try? JSONEncoder().encode(JSONValue.object(["name": .string(name)]))
            .write(to: output.appending(path: "markers/\(name).json"))
        try? await Task.sleep(for: .seconds(6))
    }

    private func waitUntil(_ timeout: Duration, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    private func check(_ name: String, _ ok: Bool, _ detail: String) {
        checks.append(.object(["check": .string(name), "ok": .bool(ok), "detail": .string(String(detail.prefix(600)))]))
        write()
    }

    private func write() {
        record["checks"] = .array(checks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? encoder.encode(JSONValue.object(record)).write(to: output.appending(path: "result.json"), options: .atomic)
    }

    private func finish() async {
        write()
        try? "done".write(to: output.appending(path: "markers/finished"), atomically: true, encoding: .utf8)
        client.terminateHost()
        try? await Task.sleep(for: .seconds(1))
        _exit(0)
    }
}
#endif
