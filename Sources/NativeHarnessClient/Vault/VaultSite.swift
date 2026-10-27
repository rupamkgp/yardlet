import Foundation

/// The Public Suffix List (publicsuffix.org, bundled as `public_suffix_list.dat`): which part of a
/// host anyone may register under, so `github.com` is one site and `alice.github.io` another.
struct PublicSuffixList: Sendable {
    private let rules: Set<String>
    private let wildcards: Set<String>
    private let exceptions: Set<String>

    init(text: String) {
        var rules = Set<String>()
        var wildcards = Set<String>()
        var exceptions = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let rule = line.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            guard !rule.isEmpty, !rule.hasPrefix("//") else { continue }
            let lowered = rule.lowercased()
            if lowered.hasPrefix("!") {
                exceptions.insert(String(lowered.dropFirst()))
            } else if lowered.hasPrefix("*.") {
                wildcards.insert(String(lowered.dropFirst(2)))
            } else {
                rules.insert(lowered)
            }
        }
        self.rules = rules
        self.wildcards = wildcards
        self.exceptions = exceptions
    }

    /// The list Yardlet ships, read the first time a site is suggested or checked; empty when the
    /// resource is missing, which leaves every host its own site. A packaged app reads only its own
    /// Resources: SwiftPM's `Bundle.module` points into the developer's build folder, which a QA app
    /// may not open (macOS asks about Desktop and Documents).
    static let bundled: PublicSuffixList = {
        let packaged = Bundle.main.bundleURL.pathExtension == "app"
        let url = Bundle.main.url(forResource: "public_suffix_list", withExtension: "dat")
            ?? (packaged ? nil : Bundle.module.url(forResource: "public_suffix_list", withExtension: "dat"))
        let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return PublicSuffixList(text: text)
    }()

    /// The number of labels in the host's public suffix (at least one).
    private func suffixLength(of labels: [String]) -> Int {
        var longest = 1
        for index in labels.indices {
            let candidate = labels[index...].joined(separator: ".")
            if exceptions.contains(candidate) { return labels.count - index - 1 }
            if rules.contains(candidate) { longest = max(longest, labels.count - index) }
            if index + 1 < labels.count, wildcards.contains(labels[(index + 1)...].joined(separator: ".")) {
                longest = max(longest, labels.count - index)
            }
        }
        return longest
    }

    /// `www.github.com` → `github.com`; nil for a public suffix itself (`com`, `github.io`).
    func registrableDomain(of host: String) -> String? {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard !labels.isEmpty, !labels.contains(where: \.isEmpty) else { return nil }
        let length = suffixLength(of: labels)
        guard labels.count > length else { return nil }
        return labels.suffix(length + 1).joined(separator: ".")
    }

    func isPublicSuffix(_ host: String) -> Bool {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        return !labels.isEmpty && suffixLength(of: labels) >= labels.count
    }
}

/// Which pages an item's sites cover (design §6.2). A site is a host (`github.com`: that host and its
/// subdomains, over https) or an exact origin for a development server (`http://localhost:3000`).
enum VaultSite {
    private static let localHosts: Set<String> = ["localhost", "127.0.0.1", "[::1]", "::1"]

    /// The page's origin as `scheme://host[:port]`, from the address the browser reports.
    static func origin(of address: String) -> String? {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(),
              let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    /// The form a site is kept in, from what the person typed or a page's address; nil for something
    /// no page could match, such as a public suffix (`com`, `github.io`) or a plain-http public site.
    static func normalize(_ text: String, suffixes: PublicSuffixList = .bundled) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") {
            guard let origin = origin(of: trimmed), let url = URL(string: origin),
                  let host = url.host(percentEncoded: false) else { return nil }
            switch url.scheme {
            case "http":
                return localHosts.contains(host) ? origin : nil
            case "https":
                return localHosts.contains(host) ? origin : normalize(host, suffixes: suffixes)
            default:
                return nil
            }
        }
        let host = trimmed.split(separator: "/").first.map(String.init) ?? trimmed
        let bare = host.split(separator: ":").first.map(String.init) ?? host
        guard !bare.isEmpty, !bare.hasPrefix("."), !bare.hasSuffix("."), bare.contains(".") || localHosts.contains(bare),
              !suffixes.isPublicSuffix(bare) else { return nil }
        return bare
    }

    /// The site to offer for a page: its registrable domain (`www.github.com` → `github.com`), or the
    /// exact origin of a local development server.
    static func suggestion(for address: String, suffixes: PublicSuffixList = .bundled) -> String? {
        guard let origin = origin(of: address), let url = URL(string: origin),
              let host = url.host(percentEncoded: false) else { return nil }
        if localHosts.contains(host) { return origin }
        guard url.scheme == "https" else { return nil }
        // An address has no registrable domain: `192.168.1.1` is that one host, not `1.1`.
        if isAddress(host) { return host }
        return suffixes.registrableDomain(of: host) ?? normalize(host, suffixes: suffixes)
    }

    /// An IP address rather than a name.
    static func isAddress(_ host: String) -> Bool {
        host.contains(":") || (!host.isEmpty && host.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") })
    }

    /// Whether a page at `origin` is one of the site's pages.
    static func matches(_ site: String, origin pageOrigin: String) -> Bool {
        guard let page = origin(of: pageOrigin), let url = URL(string: page),
              let host = url.host(percentEncoded: false) else { return false }
        if site.contains("://") { return origin(of: site) == page }
        guard url.scheme == "https", !isAddress(host) && !isAddress(site) || host == site else { return false }
        return host == site || host.hasSuffix("." + site)
    }

    /// Whether a name, such as an authenticator app's issuer, names the site: the name or its first word
    /// is the site's own label (`Vercel` for `vercel.com`, `Amazon Web Services` for `amazon.com`), apart
    /// from case, spaces and punctuation. The public suffix is not compared (`vercel.co` is named too), so
    /// this only suggests an item; the person choosing it there is what saves the site.
    static func isNamed(_ site: String, by name: String) -> Bool {
        guard !site.contains("://"), let label = site.split(separator: ".").first else { return false }
        let own = label.lowercased().filter { $0.isLetter || $0.isNumber }
        let words = name.lowercased().split { !$0.isLetter && !$0.isNumber }
        return !own.isEmpty && (words.first.map(String.init) == own || words.joined() == own)
    }

    /// The display host of a page origin (`https://www.github.com` → `www.github.com`).
    static func host(of address: String) -> String {
        URL(string: address)?.host(percentEncoded: false) ?? address
    }
}
