import Foundation

enum CodexTurnProgressProjection {
    enum CompletedDuration: Equatable {
        case seconds(Int64)
        case minutes(Int64)
        case hours(Int64)
    }

    static func elapsedSeconds(startedAt: Date, now: Date) -> Int64 {
        max(0, Int64(now.timeIntervalSince(startedAt).rounded(.down)))
    }

    /// The line above a finished turn's work. A turn the person stopped reads as stopped, as the
    /// Codex app shows it, rather than as work that finished.
    static func finishedTitle(status: CodexTurnStatus, duration: CompletedDuration?) -> String {
        let stopped = status == .interrupted
        switch duration {
        case let .seconds(value)?:
            return stopped
                ? L10n.format("You stopped after %lld seconds", value)
                : L10n.format("Worked for %lld seconds", value)
        case let .minutes(value)?:
            return stopped
                ? L10n.format("You stopped after %lld minutes", value)
                : L10n.format("Worked for %lld minutes", value)
        case let .hours(value)?:
            return stopped
                ? L10n.format("You stopped after %lld hours", value)
                : L10n.format("Worked for %lld hours", value)
        case nil:
            switch status {
            case .inProgress: return L10n.string("In progress")
            case .completed: return L10n.string("Completed")
            case .interrupted: return L10n.string("Stopped")
            case .failed: return L10n.string("Failed")
            case .unknown: return L10n.string("Unknown")
            }
        }
    }

    static func showsThinking(status: CodexTurnStatus, hasAgentOutput: Bool) -> Bool {
        guard case .inProgress = status else { return false }
        return !hasAgentOutput
    }

    static func completedDuration(
        durationMilliseconds: Int64?,
        startedAt: Date?,
        completedAt: Date?
    ) -> CompletedDuration? {
        let milliseconds: Int64?
        if let durationMilliseconds, durationMilliseconds >= 0 {
            milliseconds = durationMilliseconds
        } else if let startedAt, let completedAt, completedAt >= startedAt {
            milliseconds = Int64(completedAt.timeIntervalSince(startedAt) * 1_000)
        } else {
            milliseconds = nil
        }

        guard let milliseconds else { return nil }
        let seconds = milliseconds == 0 ? 0 : max(1, milliseconds / 1_000)
        if seconds < 60 {
            return .seconds(seconds)
        }
        if seconds < 3_600 {
            return .minutes(max(1, seconds / 60))
        }
        return .hours(max(1, seconds / 3_600))
    }
}
