import Foundation

/// One row of the address field's suggestions (Chrome's `AutocompleteMatch`, in short).
struct BrowserAddressSuggestion: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable { case page, search }

    let kind: Kind
    /// Where choosing the row goes.
    let destination: String
    /// What the field shows while the row is selected (Chrome's `fill_into_edit`): a page's address without
    /// http(s):// and www. unless the person typed them, or a search's words.
    let fill: String
    /// A page's title; empty for a search.
    var title = ""
    var relevance: Int
    /// The row can be the first one, which Return opens (Chrome's `allowed_to_be_default_match`).
    var canBeDefault = false
    /// From the person's history, so Shift-Delete removes it (Chrome's `deletable`).
    var isFromHistory = false
    /// What follows the typed text in `fill`, shown selected after the caret while the row is first (Chrome's
    /// inline autocompletion).
    var inlineCompletion = ""
    /// What the person typed, as typed: the address, or the search at the default engine.
    var isVerbatim = false

    var id: String { "\(kind)|\(destination)" }
}

/// The default search engine's suggestions for what the person typed: the answer of Google's suggest service to
/// Chrome's `SearchProvider`, `[query, [suggestion], [description], [], {"google:suggesttype": […],
/// "google:suggestrelevance": […], …}]`.
struct BrowserSearchSuggestions: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        var text: String
        /// A page Google suggests (`NAVIGATION`), whose description is its title; otherwise a search.
        var isPage: Bool
        var title: String
        var relevance: Int
    }

    var query: String
    var items: [Item]

    static func parse(_ data: Data) -> BrowserSearchSuggestions? {
        // As Chrome's `DeserializeJsonData`: whatever comes before the first "[" (the ")]}'" guard) is dropped.
        guard let start = data.firstIndex(of: UInt8(ascii: "[")),
              let array = try? JSONSerialization.jsonObject(with: data[start...]) as? [Any], array.count >= 2,
              let query = array[0] as? String, let texts = array[1] as? [String] else { return nil }
        let descriptions = array.count > 2 ? array[2] as? [String] ?? [] : []
        let extras = array.count > 4 ? array[4] as? [String: Any] : nil
        let types = extras?["google:suggesttype"] as? [String] ?? []
        let relevances = extras?["google:suggestrelevance"] as? [Int] ?? []
        func value<T>(_ list: [T], _ index: Int) -> T? { list.indices.contains(index) ? list[index] : nil }
        let items = texts.enumerated().map { index, text in
            // Without the server's relevance, below the history and verbatim rows, in the server's order.
            Item(text: text, isPage: value(types, index) == "NAVIGATION", title: value(descriptions, index) ?? "",
                 relevance: value(relevances, index) ?? 550 - index)
        }
        return BrowserSearchSuggestions(query: query, items: items)
    }
}

/// Chrome's omnibox for the address field: which rows it shows for what the person typed and in what order
/// (docs/BROWSER_HOST.md, "Address suggestions"). The numbers are Chromium's: what-you-typed and inline completion
/// from `HistoryURLProvider`, history matches from `HistoryQuickProvider` and `ScoredHistoryMatch`, past and
/// suggested searches from `SearchProvider`, and the order and count from `AutocompleteResult`.
enum BrowserAddressRanking {
    typealias Page = BrowserAddressHistory.Page
    typealias Search = BrowserAddressHistory.Search

    /// `AutocompleteResult::GetMaxMatches`, and the 10 it allows when no page is among them.
    static let maxRows = 8
    static let maxRowsOfSearches = 10
    /// Each provider's own limit (`GetProviderMaxMatches`).
    static let providerMaxMatches = 3

    // HistoryURLProvider.
    static let bestInlineableRelevance = 1413
    static let whatYouTypedRelevance = 1203
    static let nonInlineableRelevance = 900
    // SearchProvider's verbatim search (`kNonURLVerbatimRelevance`).
    static let verbatimSearchRelevance = 1300

    static func suggestions(for input: String, pages: [Page], searches: [Search], remote: BrowserSearchSuggestions?,
                            allowsInline: Bool, now: Date) -> [BrowserAddressSuggestion] {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let forcedSearch = text.hasPrefix("?")
        let query = (forcedSearch ? String(text.dropFirst()) : text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let isAddress = !forcedSearch && BrowserURLPolicy.looksLikeAddress(text)
        var rows: [BrowserAddressSuggestion] = []

        let significant = forcedSearch ? [] : pages.filter { isSignificant($0, now: now) }
        var verbatim: BrowserAddressSuggestion?
        if isAddress {
            if let url = try? BrowserURLPolicy.resolve(text) {
                // A visited address goes first (HistoryURLProvider promotes it; HistoryQuickProvider stays below).
                let visited = pages.first { BrowserURLPolicy.sameAddress($0.url, url) }
                verbatim = BrowserAddressSuggestion(
                    kind: .page, destination: visited?.url ?? url, fill: text, title: visited?.title ?? "",
                    relevance: visited == nil ? whatYouTypedRelevance : bestInlineableRelevance,
                    canBeDefault: true, isFromHistory: visited != nil, isVerbatim: true)
            }
        } else if let url = try? BrowserURLPolicy.search(query) {
            verbatim = BrowserAddressSuggestion(kind: .search, destination: url, fill: query,
                                                relevance: verbatimSearchRelevance, canBeDefault: true, isVerbatim: true)
        }
        if let verbatim { rows.append(verbatim) }

        rows += pageMatches(for: text, in: significant, isAddress: isAddress, verbatim: verbatim,
                            allowsInline: allowsInline, now: now)
        rows += pastSearches(for: query, in: searches, isAddress: isAddress, now: now)
        if let remote { rows += remoteSuggestions(for: query, in: remote) }
        return arranged(rows)
    }

    // MARK: History pages

    /// A page worth suggesting (`RowQualifiesAsSignificant`): typed once, visited four times, or in the last 3 days.
    static func isSignificant(_ page: Page, now: Date) -> Bool {
        page.typedCount >= 1 || page.visitCount >= 4 || now.timeIntervalSince(page.lastVisit) < 3 * 86_400
    }

    /// HistoryURLProvider's prefix matches (inline completion) and HistoryQuickProvider's term matches, each its
    /// best three, one row per page at the higher relevance.
    private static func pageMatches(for text: String, in pages: [Page], isAddress: Bool, verbatim: BrowserAddressSuggestion?,
                                    allowsInline: Bool, now: Date) -> [BrowserAddressSuggestion] {
        let prefixed = pages.compactMap { page in prefixMatch(text, in: page).map { (page: page, match: $0) } }
            .sorted { isBetterPrefixMatch($0, than: $1) }
            .prefix(providerMaxMatches)
        var rows: [String: BrowserAddressSuggestion] = [:]
        for (index, candidate) in prefixed.enumerated() {
            let inline = index == 0 && canInline(candidate.page)
            rows[candidate.page.url] = row(for: candidate.page, match: candidate.match,
                                           relevance: inline ? bestInlineableRelevance : nonInlineableRelevance - index,
                                           allowsInline: allowsInline)
        }
        // HistoryQuickProvider stays below a what-you-typed address that goes first (`MaxMatchScore`).
        let cap = verbatim.map { $0.kind == .page && $0.isFromHistory ? $0.relevance - 1 : Int.max } ?? Int.max
        let terms = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let scored = pages.compactMap { page -> (Page, Int)? in
            let score = quickScore(terms: terms, page: page, now: now)
            return score > 0 ? (page, min(score, cap)) : nil
        }
        .sorted { $0.1 > $1.1 }
        .prefix(providerMaxMatches)
        for (page, score) in scored where score > rows[page.url]?.relevance ?? 0 {
            rows[page.url] = row(for: page, match: prefixMatch(text, in: page), relevance: score, allowsInline: allowsInline)
        }
        return rows.values.filter { row in
            verbatim.map { !($0.kind == .page && BrowserURLPolicy.sameAddress($0.destination, row.destination)) } ?? true
        }
    }

    private static func row(for page: Page, match: PrefixMatch?, relevance: Int, allowsInline: Bool) -> BrowserAddressSuggestion {
        let completion = match.map { String($0.shown.dropFirst($0.typedCount)) } ?? ""
        // A completion shows only while the person types at the end; a page typed in full is first either way.
        let canBeDefault = match != nil && (allowsInline || completion.isEmpty)
        return BrowserAddressSuggestion(kind: .page, destination: page.url, fill: match?.shown ?? shownAddress(page.url),
                                        title: page.title, relevance: relevance, canBeDefault: canBeDefault,
                                        isFromHistory: true, inlineCompletion: canBeDefault ? completion : "")
    }

    struct PrefixMatch: Equatable {
        /// The page's address as the field shows it, starting with what was typed.
        var shown: String
        var typedCount: Int
        /// Matched after http(s):// and www. both (Chrome's `innermost_match`).
        var isInnermost: Bool
    }

    /// The typed text as the start of the page's address, with the scheme and www. left off when the person did
    /// not type them (`URLPrefix::GetURLPrefixes`).
    static func prefixMatch(_ text: String, in page: Page) -> PrefixMatch? {
        let typed = text.lowercased()
        guard !typed.isEmpty, !typed.contains(where: \.isWhitespace) else { return nil }
        let full = displayed(page.url)
        var forms = [(full, false)]
        if let scheme = full.range(of: "://") {
            let rest = String(full[scheme.upperBound...])
            forms.append((rest, !rest.lowercased().hasPrefix("www.")))
            if rest.lowercased().hasPrefix("www.") { forms.append((String(rest.dropFirst(4)), true)) }
        }
        for (form, innermost) in forms.reversed() {
            var shown = form
            // A host's root shows without its slash ("github.com"), unless the person typed it.
            if shown.hasSuffix("/"), shown.dropLast().lowercased().hasPrefix(typed),
               URLComponents(string: page.url).map({ ($0.path.isEmpty || $0.path == "/") && $0.query == nil && $0.fragment == nil }) == true {
                shown.removeLast()
            }
            if shown.lowercased().hasPrefix(typed) {
                return PrefixMatch(shown: shown, typedCount: typed.count, isInnermost: innermost)
            }
        }
        return nil
    }

    /// HistoryURLProvider inlines a host typed once, or another page typed twice
    /// (`CanPromoteMatchForInlineAutocomplete`).
    static func canInline(_ page: Page) -> Bool {
        page.typedCount > 1 || (page.typedCount == 1 && isHostOnly(page.url))
    }

    private static func isHostOnly(_ url: String) -> Bool {
        guard let components = URLComponents(string: url) else { return false }
        return (components.path.isEmpty || components.path == "/") && components.query == nil && components.fragment == nil
    }

    /// `CompareHistoryMatch`: typed at all, matched after the scheme and www., typed more often, a host over a page
    /// for pages typed once, visited more often, visited more recently.
    private static func isBetterPrefixMatch(_ a: (page: Page, match: PrefixMatch), than b: (page: Page, match: PrefixMatch)) -> Bool {
        if (a.page.typedCount > 0) != (b.page.typedCount > 0) { return a.page.typedCount > 0 }
        if a.match.isInnermost != b.match.isInnermost { return a.match.isInnermost }
        if a.page.typedCount != b.page.typedCount { return a.page.typedCount > b.page.typedCount }
        if a.page.typedCount == 1, isHostOnly(a.page.url) != isHostOnly(b.page.url) { return isHostOnly(a.page.url) }
        if a.page.visitCount != b.page.visitCount { return a.page.visitCount > b.page.visitCount }
        return a.page.lastVisit > b.page.lastVisit
    }

    /// `ScoredHistoryMatch`: every term must match at a word start of the address or title (in the host, inside a
    /// word too); topicality times frequency, through Chrome's relevance buckets.
    static func quickScore(terms: [String], page: Page, now: Date) -> Int {
        // Most pages hold some term nowhere; they go before their addresses are read.
        let text = displayed(page.url).lowercased() + " " + page.title.lowercased()
        guard !terms.isEmpty, terms.allSatisfy(text.contains) else { return 0 }
        var topicality: Double = 0
        for term in terms {
            let score = urlTermScore(term, url: page.url) + titleTermScore(term, title: page.title)
            guard score > 0 else { return 0 }
            topicality += topicalityScore(rawTermScore: score)
        }
        topicality /= Double(terms.count)
        guard topicality >= 0.5 else { return 0 }
        return relevance(topicality * frequency(of: page, now: now))
    }

    /// `IncrementUrlMatchTermScores`: 10 at a word start of the host (2 inside a word), 8 in the path, 5 in the
    /// query or fragment; nothing in the scheme, or in the top-level domain unless the term has a dot.
    static func urlTermScore(_ term: String, url: String) -> Int {
        guard let components = URLComponents(string: url), let host = components.host?.lowercased(), !host.isEmpty else {
            return 0
        }
        let path = (components.percentEncodedPath.removingPercentEncoding ?? components.percentEncodedPath).lowercased()
        var tail = ""
        if let query = components.percentEncodedQuery { tail += "?" + (query.removingPercentEncoding ?? query) }
        if let fragment = components.percentEncodedFragment { tail += "#" + (fragment.removingPercentEncoding ?? fragment) }
        let text = Array(host + path + tail.lowercased())
        let pathStart = host.count, queryStart = host.count + path.count
        let lastLabel = host.lastIndex(of: ".").map { host.distance(from: host.startIndex, to: $0) } ?? host.count
        let starts = wordStarts(text)
        let allowsTopLevelDomain = term.contains(".")
        var score = 0
        for word in occurrences(of: term, in: text) {
            let atWordStart = starts.contains(word)
            if word >= queryStart {
                if atWordStart { score += 5 }
            } else if word >= pathStart {
                if atWordStart { score += 8 }
            } else if word < lastLabel {
                score += atWordStart ? 10 : 2
            } else if allowsTopLevelDomain, atWordStart {
                score += 10
            }
        }
        return score
    }

    /// `IncrementTitleMatchTermScores`: 8 at each word start in the title's first 20 words.
    static func titleTermScore(_ term: String, title: String) -> Int {
        let text = Array(title.lowercased())
        let starts = Set(wordStarts(text).sorted().prefix(20))
        return occurrences(of: term, in: text).filter(starts.contains).count * 8
    }

    /// Where each word starts: a letter or digit after anything else.
    private static func wordStarts(_ text: [Character]) -> Set<Int> {
        Set(text.indices.filter { isWordCharacter(text[$0]) && ($0 == 0 || !isWordCharacter(text[$0 - 1])) })
    }

    private static func isWordCharacter(_ character: Character) -> Bool { character.isLetter || character.isNumber }

    /// Where the term's word part (after any leading punctuation, as in "/path") falls at each of its
    /// non-overlapping occurrences, as Chrome's term matching finds them.
    private static func occurrences(of term: String, in text: [Character]) -> [Int] {
        let characters = Array(term)
        guard !characters.isEmpty, characters.count <= text.count else { return [] }
        let lead = characters.prefix { !isWordCharacter($0) }.count
        var found: [Int] = []
        var index = 0
        while index + characters.count <= text.count {
            if text[index..<index + characters.count].elementsEqual(characters) {
                found.append(index + lead)
                index += characters.count
            } else {
                index += 1
            }
        }
        return found
    }

    /// `raw_term_score_to_topicality_score`: linear to 10 points, then logarithmic up to 30.
    static func topicalityScore(rawTermScore: Int) -> Double {
        let score = min(rawTermScore, 29)
        return score < 10 ? 0.1 * Double(score) : 1 + 2.25 * log10(0.1 * Double(score))
    }

    /// `GetFrequency`: the last ten visits, a typed one worth 1.5, each weighted by how recent it is.
    static func frequency(of page: Page, now: Date) -> Double {
        page.visits.prefix(BrowserAddressHistory.maxVisitsToScore).reduce(0) { sum, visit in
            sum + (visit.typed ? 1.5 : 1) * recencyScore(daysAgo: Int(now.timeIntervalSince(visit.date) / 86_400))
        }
    }

    /// `InitDaysAgoToRecencyScoreArray`.
    static func recencyScore(daysAgo: Int) -> Double {
        let days = max(0, min(daysAgo, 365))
        let score: Int
        switch days {
        case ...4: score = 100
        case ...14: score = 70 + (14 - days) * (100 - 70) / (14 - 4)
        case ...31: score = 50 + (31 - days) * (70 - 50) / (31 - 14)
        case ...90: score = 30 + (90 - days) * (50 - 30) / (90 - 30)
        default: score = 10 + (365 - days) * (20 - 10) / (365 - 90)
        }
        return Double(score) / 100
    }

    /// `GetFinalRelevancyScore` over Chrome's default buckets "0.0:550,1:625,9.0:1300,90.0:1399".
    static func relevance(_ score: Double) -> Int {
        let buckets: [(Double, Double)] = [(0, 550), (1, 625), (9, 1300), (90, 1399)]
        guard score > 0 else { return 0 }
        for index in 1..<buckets.count where score < buckets[index].0 {
            let (low, high) = (buckets[index - 1], buckets[index])
            return Int(low.1 + (high.1 - low.1) / (high.0 - low.0) * (score - low.0))
        }
        return Int(buckets[buckets.count - 1].1)
    }

    // MARK: Searches

    /// SearchProvider's past searches that start with what was typed, `CalculateRelevanceForHistory` without the
    /// aggressive curve: 1050 (750 for an address) less 6.5 × seconds^0.3.
    private static func pastSearches(for query: String, in searches: [Search], isAddress: Bool, now: Date) -> [BrowserAddressSuggestion] {
        let typed = query.lowercased()
        return searches.filter { $0.terms.lowercased().hasPrefix(typed) && $0.terms.lowercased() != typed }
            .compactMap { search -> BrowserAddressSuggestion? in
                guard let url = try? BrowserURLPolicy.search(search.terms) else { return nil }
                let elapsed = max(now.timeIntervalSince(search.lastVisit), 0)
                let relevance = max(0, (isAddress ? 750 : 1050) - Int(6.5 * pow(elapsed, 0.3)))
                return BrowserAddressSuggestion(kind: .search, destination: url, fill: search.terms,
                                                relevance: relevance, isFromHistory: true)
            }
            .sorted { $0.relevance > $1.relevance }
            .prefix(providerMaxMatches)
            .map { $0 }
    }

    /// The server's searches and pages, at its relevance. An answer for a shorter input keeps the rows that still
    /// start with what was typed, until the answer for this one comes.
    private static func remoteSuggestions(for query: String, in remote: BrowserSearchSuggestions) -> [BrowserAddressSuggestion] {
        let typed = query.lowercased()
        let current = remote.query.lowercased() == typed
        guard current || typed.hasPrefix(remote.query.lowercased()) else { return [] }
        return remote.items.compactMap { item in
            guard item.text.lowercased() != typed, current || item.text.lowercased().hasPrefix(typed) else { return nil }
            if item.isPage {
                guard let url = try? BrowserURLPolicy.resolve(item.text), BrowserURLPolicy.isAllowed(url) else { return nil }
                return BrowserAddressSuggestion(kind: .page, destination: url, fill: shownAddress(url), title: item.title,
                                                relevance: item.relevance)
            }
            guard let url = try? BrowserURLPolicy.search(item.text) else { return nil }
            return BrowserAddressSuggestion(kind: .search, destination: url, fill: item.text, relevance: item.relevance)
        }
    }

    // MARK: Order

    /// `AutocompleteResult::SortAndCull`: one row per destination at its best, the best row that can be first goes
    /// first, the best of the rest up to the limit, then searches before pages.
    private static func arranged(_ candidates: [BrowserAddressSuggestion]) -> [BrowserAddressSuggestion] {
        var best: [String: BrowserAddressSuggestion] = [:]
        var order: [String] = []
        for row in candidates {
            let key = row.kind == .search ? "search|" + row.fill.lowercased() : "page|" + normalized(row.destination)
            guard let kept = best[key] else {
                best[key] = row
                order.append(key)
                continue
            }
            var merged = row.relevance > kept.relevance ? row : kept
            merged.canBeDefault = kept.canBeDefault || row.canBeDefault
            merged.isFromHistory = kept.isFromHistory || row.isFromHistory
            merged.isVerbatim = kept.isVerbatim || row.isVerbatim
            if merged.inlineCompletion.isEmpty { merged.inlineCompletion = kept.inlineCompletion.isEmpty ? row.inlineCompletion : kept.inlineCompletion }
            if merged.title.isEmpty { merged.title = kept.title.isEmpty ? row.title : kept.title }
            best[key] = merged
        }
        // At the same relevance what was typed goes first, then the order the rows came in.
        var rows = order.compactMap { best[$0] }.enumerated().sorted { a, b in
            if a.element.relevance != b.element.relevance { return a.element.relevance > b.element.relevance }
            if a.element.isVerbatim != b.element.isVerbatim { return a.element.isVerbatim }
            return a.offset < b.offset
        }.map(\.element)
        guard !rows.isEmpty else { return [] }
        if let first = rows.firstIndex(where: \.canBeDefault) {
            rows.insert(rows.remove(at: first), at: 0)
        }
        for index in rows.indices.dropFirst() { rows[index].inlineCompletion = "" }
        let limit = rows.prefix(maxRows).dropFirst().contains { $0.kind == .page } ? maxRows : maxRowsOfSearches
        let kept = rows.prefix(limit)
        let rest = kept.dropFirst()
        return [kept[kept.startIndex]] + rest.filter { $0.kind == .search } + rest.filter { $0.kind == .page }
    }

    private static func normalized(_ url: String) -> String {
        var address = url
        if let hash = address.firstIndex(of: "#") { address = String(address[..<hash]) }
        while address.hasSuffix("/") { address.removeLast() }
        return address
    }

    /// A page's address as the dropdown and the field show it: decoded, without http(s):// or www.
    static func shownAddress(_ url: String) -> String {
        var shown = displayed(url)
        for scheme in ["https://", "http://"] where shown.lowercased().hasPrefix(scheme) {
            shown.removeFirst(scheme.count)
        }
        if shown.lowercased().hasPrefix("www.") { shown.removeFirst(4) }
        if shown.hasSuffix("/"), isHostOnly(url) { shown.removeLast() }
        return shown
    }

    private static func displayed(_ url: String) -> String {
        url.removingPercentEncoding ?? url
    }
}
