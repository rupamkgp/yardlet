import Foundation

/// The context ring beside the model menu and the window it opens, in the form the Claude app's
/// Code composer gives them (2.37337.1, `KF`/`IF` ring, `c2d611398` popover), for every harness that
/// reports how full its context window is (D5). The ring is always there for such a task, warns
/// from 75% and turns critical from 90%; hovering names "Context 45.2k / 200k (23%)", and clicking
/// opens the window: the same numbers, a bar, what fills the window where the harness breaks it down
/// (Claude Code's `/context` categories), and how far auto-compact is.
///
/// A harness that reports no window gets no ring rather than a guess.
struct ComposerContextSummary: Equatable, Sendable {
    enum Severity: Equatable, Sendable {
        case normal
        case warning
        case critical
    }

    /// One row of the breakdown's legend, in the Claude app's order: what fills the window, largest
    /// first, then the auto-compact buffer, the free space and the tools listed but not loaded.
    struct LegendRow: Equatable, Sendable, Identifiable {
        enum Kind: Equatable, Sendable {
            /// Content, coloured by its place among the largest (`colorIndex`).
            case used(colorIndex: Int)
            case buffer
            case free
            case deferred
        }

        /// The harness's own name for it, as `/context` lists it.
        let name: String
        let tokens: UInt64
        let kind: Kind
        /// The share of the window, "12.3%", or "—" for what is not in the window.
        let shareText: String

        var id: String { name }
        var tokensText: String { ComposerContextSummary.tokenText(tokens) }
    }

    /// One part of the stacked meter above the legend: at most five used categories, the rest as
    /// "Other", then the buffer.
    struct MeterSegment: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case used(colorIndex: Int)
            case other
            case buffer
        }

        let kind: Kind
        let fraction: Double
    }

    /// Tokens in the window, where reported.
    let usedTokens: UInt64?
    /// The window's size; nil before the harness first reports it.
    let windowTokens: UInt64?
    let legend: [LegendRow]
    let meter: [MeterSegment]
    /// "120k until auto-compact" or "Auto-compacts soon", where the harness compacts on its own and
    /// says when.
    let autoCompactHint: String?

    // MARK: The Claude app's constants

    /// `PF`: the ring warns from here.
    static let warningPercent = 75
    /// `FF`: and is critical from here.
    static let criticalPercent = 90
    /// `fG` `minPct`: "Compact session" is offered from here.
    static let compactOfferPercent = 50
    /// `iG`: closer than this to the threshold, auto-compact is "soon".
    static let autoCompactSoonTokens: UInt64 = 30_000
    /// `le - 1`: the meter draws this many categories before "Other".
    static let meterCategoryLimit = 5

    /// The ring for a task's reported usage. With no window: an empty ring for a harness that
    /// reports one once a turn has run (`reportsContextWindow`) and has not yet, else none.
    static func make(usage: HarnessProtocolUsage?, reportsContextWindow: Bool) -> ComposerContextSummary? {
        guard let window = usage?.contextWindowTokens, window > 0 else {
            return reportsContextWindow && usage == nil
                ? ComposerContextSummary(usedTokens: nil, windowTokens: nil, legend: [], meter: [], autoCompactHint: nil)
                : nil
        }
        let used = usage?.contextUsedTokens.map { min($0, window) }
        let breakdown = usage?.contextBreakdown
        let (legend, meter) = Self.legendAndMeter(breakdown, window: window)
        return ComposerContextSummary(
            usedTokens: used, windowTokens: window, legend: legend, meter: meter,
            autoCompactHint: used.flatMap { Self.autoCompactHint(breakdown, used: $0, window: window) }
        )
    }

    var fraction: Double? {
        guard let usedTokens, let windowTokens, windowTokens > 0 else { return nil }
        return min(max(Double(usedTokens) / Double(windowTokens), 0), 1)
    }

    var percent: Int? { fraction.map { Int(($0 * 100).rounded()) } }

    var severity: Severity {
        guard let percent else { return .normal }
        if percent >= Self.criticalPercent { return .critical }
        if percent >= Self.warningPercent { return .warning }
        return .normal
    }

    /// "45.2k / 200k (23%)", the Claude app's `qF`.
    var summaryText: String? {
        guard let usedTokens, let windowTokens, let percent else { return nil }
        return "\(Self.tokenText(usedTokens)) / \(Self.tokenText(windowTokens)) (\(percent)%)"
    }

    /// The ring's tooltip: "Context 45.2k / 200k (23%)".
    var help: String {
        summaryText.map { L10n.format("Context %@", $0) } ?? L10n.string("Send a message to see context usage.")
    }

    var offersCompact: Bool { (percent ?? 0) >= Self.compactOfferPercent }

    // MARK: Words and numbers

    /// The Claude app's `kF`: "950", "45.2k", "200k", "1.5M".
    static func tokenText(_ value: UInt64) -> String {
        func scaled(_ divisor: Double, _ suffix: String) -> String {
            var text = String(format: "%.1f", Double(value) / divisor)
            if text.hasSuffix(".0") { text.removeLast(2) }
            return text + suffix
        }
        switch value {
        case ..<1_000: return String(value)
        case ..<1_000_000: return scaled(1_000, "k")
        case ..<1_000_000_000: return scaled(1_000_000, "M")
        default: return scaled(1_000_000_000, "B")
        }
    }

    /// `rG`/`oG`: the threshold is the one reported when it lies inside the window, else the window
    /// less the buffer row; an API that compacts by itself keeps no buffer and compacts at the
    /// window. Closer than 30k it is "soon"; otherwise the distance, rounded down to two digits.
    static func autoCompactHint(_ breakdown: HarnessContextBreakdown?, used: UInt64, window: UInt64) -> String? {
        guard let breakdown, breakdown.isAutoCompactEnabled else { return nil }
        let buffer = breakdown.categories.first { $0.kind == .buffer }
        let threshold: UInt64
        if let reported = breakdown.autoCompactThresholdTokens, reported > 0, reported <= window {
            threshold = reported
        } else if breakdown.autoCompactSource == "auto", buffer == nil {
            threshold = window
        } else {
            threshold = window - min(window, buffer?.tokens ?? 0)
        }
        let remaining = threshold > used ? threshold - used : 0
        guard remaining >= autoCompactSoonTokens else { return L10n.string("Auto-compacts soon") }
        return L10n.format("%@ until auto-compact", tokenText(roundedDownToTwoDigits(remaining)))
    }

    static func roundedDownToTwoDigits(_ value: UInt64) -> UInt64 {
        var magnitude: UInt64 = 1
        while value / magnitude >= 100 { magnitude *= 10 }
        return value / magnitude * magnitude
    }

    private static func legendAndMeter(_ breakdown: HarnessContextBreakdown?,
                                       window: UInt64) -> ([LegendRow], [MeterSegment]) {
        guard let breakdown, !breakdown.categories.isEmpty else { return ([], []) }
        let measure = Double(breakdown.windowTokens ?? window)
        func share(_ tokens: UInt64) -> String { String(format: "%.1f%%", Double(tokens) / measure * 100) }
        let used = breakdown.categories.filter { $0.kind == .used && $0.tokens > 0 }
            .enumerated().sorted { $0.element.tokens != $1.element.tokens ? $0.element.tokens > $1.element.tokens
                                                                            : $0.offset < $1.offset }
            .map(\.element)
        var legend = used.enumerated().map { index, category in
            LegendRow(name: category.name, tokens: category.tokens, kind: .used(colorIndex: index),
                      shareText: share(category.tokens))
        }
        let buffers = breakdown.categories.filter { $0.kind == .buffer && $0.tokens > 0 }
        legend += buffers.map { LegendRow(name: $0.name, tokens: $0.tokens, kind: .buffer, shareText: share($0.tokens)) }
        legend += breakdown.categories.filter { $0.kind == .free }
            .map { LegendRow(name: $0.name, tokens: $0.tokens, kind: .free, shareText: share($0.tokens)) }
        legend += breakdown.categories.filter { $0.kind == .deferred }
            .map { LegendRow(name: $0.name, tokens: $0.tokens, kind: .deferred, shareText: "—") }

        var meter = used.prefix(meterCategoryLimit).enumerated().map { index, category in
            MeterSegment(kind: .used(colorIndex: index), fraction: Double(category.tokens) / measure)
        }
        let rest = used.dropFirst(meterCategoryLimit).reduce(UInt64(0)) { $0 + $1.tokens }
        if rest > 0 { meter.append(MeterSegment(kind: .other, fraction: Double(rest) / measure)) }
        meter += buffers.map { MeterSegment(kind: .buffer, fraction: Double($0.tokens) / measure) }
        return (legend, meter)
    }
}
