import Foundation

/// An armed automatic continue for one limit card, with the task identity it was armed for.
/// The continue message is sent only while the task still matches all of it.
struct UsageLimitAutoContinue: Equatable, Sendable {
    let entryID: UUID
    let resetsAt: Date
    let providerSessionID: String?
    let connection: ProviderConnection?
}

/// What a task stopped by a plan limit sends to pick up where it stopped.
enum UsageLimitContinuation {
    /// The Claude app's own message for continuing once the limit has reset.
    static var afterReset: String {
        L10n.string("I hit my usage limit while you were working, but it has reset now. Please continue from where you left off.")
    }

    /// The same request after moving to another account, which has not reset anything.
    static var afterAccountSwitch: String {
        L10n.string("I hit my usage limit while you were working, and I've switched to another account now. Please continue from where you left off.")
    }
}

/// The words a task shows for its provider's plan limits, retries and compaction, in the Claude
/// app's own phrasing where it has one.
enum ProviderNoticeText {
    static func limitHeadline(_ limit: HarnessRateLimit) -> String {
        switch limit.window {
        case .session: L10n.string("Session limit reached")
        case .weekly: L10n.string("Weekly limit reached")
        case .model: limit.model.map { L10n.format("%@ limit reached", $0) } ?? L10n.string("Usage limit reached")
        case .overage, nil: L10n.string("Usage limit reached")
        }
    }

    /// When the limit resets, with the day named unless it is today.
    static func limitReset(_ limit: HarnessRateLimit, now: Date = Date()) -> String? {
        guard let resetsAt = limit.resetsAt else { return nil }
        let time = resetTime(resetsAt, now: now)
        return switch limit.window {
        case .session: L10n.format("Your session limit resets at %@.", time)
        case .weekly: L10n.format("Your weekly limit resets at %@.", time)
        case .model: limit.model.map { L10n.format("Your %1$@ limit resets at %2$@.", $0, time) }
            ?? L10n.format("Your usage limit resets at %@.", time)
        case .overage, nil: L10n.format("Your usage limit resets at %@.", time)
        }
    }

    static func resetTime(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// A warning's one line: how much of the window is used, or that it is close, and its reset.
    static func limitWarning(_ limit: HarnessRateLimit, now: Date = Date()) -> String {
        let percent = limit.usedFraction.map { Int64(min(100, max(0, ($0 * 100).rounded(.down)))) }
        let usage: String = switch (limit.window, percent) {
        case let (.session, percent?): L10n.format("You've used %lld%% of your session limit", percent)
        case (.session, nil): L10n.string("Approaching your session limit")
        case let (.weekly, percent?): L10n.format("You've used %lld%% of your weekly limit", percent)
        case (.weekly, nil): L10n.string("Approaching your weekly limit")
        case let (.model, percent?):
            limit.model.map { L10n.format("You've used %2$lld%% of your %1$@ limit", $0, percent) }
                ?? L10n.format("You've used %lld%% of your usage limit", percent)
        case let (_, percent?): L10n.format("You've used %lld%% of your usage limit", percent)
        case (_, nil): L10n.string("Approaching your usage limit")
        }
        guard let resetsAt = limit.resetsAt else { return usage }
        return usage + " · " + L10n.format("Resets %@", resetTime(resetsAt, now: now))
    }

    /// The running status line while the provider retries: why, then which attempt of how many.
    static func retry(_ retry: HarnessProviderRetry) -> String {
        let attempt = L10n.format("Retrying (%lld/%lld)", Int64(retry.attempt), Int64(retry.maxRetries))
        let cause: String? = switch retry.cause {
        case .overloaded: L10n.string("API overloaded")
        case .rateLimited: L10n.string("Rate limited")
        case .serverError: L10n.string("Server error")
        case .connection: L10n.string("Network error")
        case .other: nil
        }
        return cause.map { "\($0) · \(attempt)" } ?? attempt
    }

    static func compaction(_ compaction: HarnessContextCompaction) -> String {
        switch compaction.phase {
        case .started:
            return L10n.string("Compacting session…")
        case .failed:
            return L10n.string("Compaction failed")
        case .completed:
            if let saved = compaction.savedTokens {
                return L10n.format("Compacted session · saved %@ tokens",
                    ConversationSessionStatusProjection.compactTokenCount(saved))
            }
            if let before = compaction.tokensBefore {
                return L10n.format("Compacted session · from %@ tokens",
                    ConversationSessionStatusProjection.compactTokenCount(before))
            }
            return L10n.string("Compacted session")
        }
    }
}
