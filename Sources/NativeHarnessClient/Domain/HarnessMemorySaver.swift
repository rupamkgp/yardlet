import Foundation

/// The memory saver for tasks' harness runtimes (Settings › General "Memory saver"), each harness the way its own app lets an idle
/// conversation go. A Claude Code task's CLI ends; a Codex task's thread is let go in the App
/// Server its account shares (`thread/unsubscribe`), which unloads it. Nothing is sent to the conversation: the next
/// message resumes the same provider session, as after an idle runtime ends on its own.
///
/// - Claude app 3.6556.2 (`CliGovernor`): on macOS memory pressure (warning or critical), CLIs idle for at least a
///   minute end, longest idle first, until two fewer than its cap run; one pressure sweep a minute.
/// - Codex app 26.1021 (its inactive-conversation unloader): a conversation no one has looked at for 3 hours is let go,
///   and so is the oldest beyond 10 such conversations.
/// - Yardlet also lets a Claude Code task's CLI go after those 3 hours: the Claude app keeps a person's CLIs until
///   memory runs short, while Yardlet keeps many more tasks open at once.
///
/// What keeps a runtime whatever the rules (`Runtime.keptBy`) is AppModel's to say: a turn, a question, a queued
/// message, a background shell or schedule, a terminal, running child work, an edit, the task on screen.
enum HarnessMemorySaver {
    struct Timing: Equatable, Sendable {
        /// The Codex app lets a conversation go once no one has looked at it this long (3 hours).
        var unseenBeforeRelease: TimeInterval = 3 * 3600
        /// Memory pressure ends a Claude CLI only once it has been idle this long, and sweeps once a minute.
        var pressureIdleGuard: TimeInterval = 60
        var pressureSpacing: TimeInterval = 60
        /// How often Yardlet looks.
        var checkInterval: TimeInterval = 60
    }

    /// The most Codex conversations the Codex app keeps loaded that no one is looking at.
    static let codexLoadedLimit = 10

    /// The Claude app's cap on running CLIs: one for every 3 GiB of memory, at least 6 (10 on a 32 GB Mac).
    static func claudeCap(physicalMemory: UInt64) -> Int {
        max(6, Int(physicalMemory / (3 << 30)))
    }

    enum Kind: Equatable, Sendable {
        /// A Claude Code CLI of its own.
        case claudeProcess
        /// A thread in the Codex App Server the task's account shares.
        case codexThread
    }

    struct Runtime: Equatable, Sendable {
        var task: UUID
        var kind: Kind
        /// Since when the task has been idle and off screen: the later of its last activity and the last moment it
        /// was on screen.
        var idleSince: Date
        /// What keeps the runtime whatever the rules (a turn, a question, a schedule, a background shell, the task on
        /// screen …); nil when the saver may end it.
        var keptBy: String?
    }

    /// The runtimes to end now, longest idle first. `pressureSweep`: macOS reports memory pressure and the last sweep
    /// was at least `Timing.pressureSpacing` ago.
    static func releases(_ runtimes: [Runtime], now: Date, pressureSweep: Bool, physicalMemory: UInt64,
                         timing: Timing = Timing()) -> [UUID] {
        let free = runtimes.filter { $0.keptBy == nil }.sorted { $0.idleSince < $1.idleSince }
        var picked: [UUID] = []
        for runtime in free where now.timeIntervalSince(runtime.idleSince) >= timing.unseenBeforeRelease {
            picked.append(runtime.task)
        }
        let codex = free.filter { $0.kind == .codexThread && !picked.contains($0.task) }
        picked += codex.prefix(max(0, codex.count - codexLoadedLimit)).map(\.task)
        if pressureSweep {
            let running = runtimes.filter { $0.kind == .claudeProcess && !picked.contains($0.task) }.count
            var excess = running - max(1, claudeCap(physicalMemory: physicalMemory) - 2)
            for runtime in free where excess > 0 && runtime.kind == .claudeProcess && !picked.contains(runtime.task)
                && now.timeIntervalSince(runtime.idleSince) >= timing.pressureIdleGuard {
                picked.append(runtime.task)
                excess -= 1
            }
        }
        return picked
    }
}
