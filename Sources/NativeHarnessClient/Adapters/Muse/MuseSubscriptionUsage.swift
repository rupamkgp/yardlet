import Foundation

/// The subscription usage a Muse host last observed: the `usage` member of `usage/read` and the
/// params of `usage/changed` (MSP `SubscriptionUsage`). The percentages are the provider's own,
/// verbatim and allowed above 100, and `observedAt` is when the host received them, so the value
/// is shown "as of" that time rather than as live data.
struct MuseSubscriptionUsage: Equatable, Sendable {
    struct Window: Equatable, Sendable {
        let usedPercent: Double
        /// The window's length. MSP sends it for the current window and not for the weekly one.
        let durationMinutes: Double?
        let resetsAt: Date?
    }

    /// The current usage window, the provider's 5-hour-class block.
    let window: Window?
    /// The rolling weekly block.
    let weekly: Window?
    /// The provider's subscription tier id, verbatim.
    let tier: String?
    let observedAt: Date

    /// Nil when the value carries no window with a usable percentage or no arrival stamp.
    init?(_ value: JSONValue?) {
        guard let value,
              let observedAtMs = value["observedAtMs"]?.doubleValue, observedAtMs.isFinite
        else { return nil }
        let window = Self.window(value["window"], durationKey: "windowDurationMins")
        let weekly = Self.window(value["weekly"], durationKey: nil)
        guard window != nil || weekly != nil else { return nil }
        self.window = window
        self.weekly = weekly
        tier = value["tier"]?.stringValue
        observedAt = Date(timeIntervalSince1970: observedAtMs / 1_000)
    }

    private static func window(_ value: JSONValue?, durationKey: String?) -> Window? {
        guard let used = value?["usedPercent"]?.doubleValue, used.isFinite, used >= 0 else {
            return nil
        }
        let duration = durationKey
            .flatMap { value?[$0]?.doubleValue }
            .flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let resetsAt = value?["resetsAtMs"]?.doubleValue
            .flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0 / 1_000) : nil }
        return Window(usedPercent: used, durationMinutes: duration, resetsAt: resetsAt)
    }
}

/// The last subscription usage each Muse runtime reported, for the Account Center. A Muse host
/// observes usage only from its own model calls, so a separately started host would have nothing
/// to report; the session adapter that owns the live host records what it reads here instead.
actor MuseSubscriptionUsageStore {
    static let shared = MuseSubscriptionUsageStore()

    private var latestByHarness: [HarnessKind: MuseSubscriptionUsage] = [:]

    /// Keeps the newer observation, so a late read cannot replace a fresher push.
    func record(_ usage: MuseSubscriptionUsage, for harness: HarnessKind) {
        if let current = latestByHarness[harness], current.observedAt > usage.observedAt { return }
        latestByHarness[harness] = usage
    }

    func latest(for harness: HarnessKind) -> MuseSubscriptionUsage? {
        latestByHarness[harness]
    }
}
