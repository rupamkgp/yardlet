import AppKit
import Foundation
import Observation

/// Install Update… › "Restart When Tasks Finish", the Claude app's wait for running work before it
/// restarts for an update (it says it is waiting for Claude to finish and will restart on its own). Yardlet
/// installs once no task has run for a few seconds and the staged build is still the one the person
/// chose. The install goes through the ordinary quit, which still refuses while a task runs. Sparkle's
/// Install and Relaunch waits the same way (`YardletSparkle`).
enum YardletUpdateWaitPolicy {
    /// How long no task must have run. A follow-up queued behind a finishing turn starts the next
    /// one moments later, and installing in between would cut it off.
    static let quietPeriod: TimeInterval = 5
    static let checkInterval: Duration = .seconds(1)

    enum Step: Equatable {
        /// Tasks run, or have not been quiet long enough; `quietSince` is when the last one stopped.
        case wait(quietSince: Date?)
        case install
    }

    static func step(activeTasks: Int, quietSince: Date?, now: Date,
                     quietPeriod: TimeInterval = quietPeriod) -> Step {
        guard activeTasks == 0 else { return .wait(quietSince: nil) }
        let since = quietSince ?? now
        return now.timeIntervalSince(since) >= quietPeriod ? .install : .wait(quietSince: since)
    }

    /// Whether the build staged now is the one the person chose to wait for. Another build staged
    /// meanwhile, or none, is not installed without asking again.
    static func isStillChosen(_ chosen: YardletUpdater.Candidate, staged: YardletUpdater.Candidate?) -> Bool {
        staged?.executableDigest == chosen.executableDigest
    }
}

/// What Install Update… offers for a staged build. With tasks running, waiting for them comes
/// first: it stops nothing.
enum YardletUpdateOffer: Equatable {
    case waitForTasks
    case installNow
    case cancel

    static func choices(hasRunningTasks: Bool) -> [Self] {
        hasRunningTasks ? [.waitForTasks, .installNow, .cancel] : [.installNow, .cancel]
    }

    var title: String {
        switch self {
        case .waitForTasks: L10n.string("Restart When Tasks Finish")
        case .installNow: L10n.string("Install and Restart")
        case .cancel: L10n.string("Cancel")
        }
    }

    /// The alert asking to install `build`, made `date`, with a button for each choice in order.
    @MainActor
    static func alert(build: String, date: String, hasRunningTasks: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = L10n.string("Install the staged Yardlet build?")
        var message = L10n.format(
            "Build %@, made %@. Yardlet quits, installs it, and opens again. Tasks, drafts and history stay as they are, and the current app is kept for rollback.",
            build, date)
        if hasRunningTasks {
            message += "\n\n" + L10n.string("Tasks are still running. Yardlet can wait until they finish, then install and restart on its own.")
        }
        alert.informativeText = message
        for choice in choices(hasRunningTasks: hasRunningTasks) { alert.addButton(withTitle: choice.title) }
        return alert
    }

    /// The choice an alert made by `alert(…)` answered with.
    static func choice(for response: NSApplication.ModalResponse, hasRunningTasks: Bool) -> Self {
        let choices = choices(hasRunningTasks: hasRunningTasks)
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return choices.indices.contains(index) ? choices[index] : .cancel
    }
}

/// The menu lines for updates: Install Update… for a staged build, or Check for Updates… in a build
/// that updates with Sparkle; while Yardlet waits for tasks to finish, a dimmed "Waiting to Update"
/// and Cancel Update instead. The app menu and the sidebar's account menu list the same ones.
enum YardletUpdateMenu: Hashable {
    case install
    case checkForUpdates
    case waiting
    case cancelWaiting

    static func items(isWaiting: Bool, checksForUpdates: Bool = false) -> [Self] {
        isWaiting ? [.waiting, .cancelWaiting] : [checksForUpdates ? .checkForUpdates : .install]
    }

    var title: String {
        switch self {
        case .install: L10n.string("Install Update…")
        case .checkForUpdates: L10n.string("Check for Updates…")
        case .waiting: L10n.string("Waiting to Update")
        case .cancelWaiting: L10n.string("Cancel Update")
        }
    }

    /// The waiting line says what is happening; it does nothing.
    var isEnabled: Bool { self != .waiting }

    var help: String? {
        self == .waiting ? L10n.string("Yardlet installs the update and restarts once no task is running.") : nil
    }
}

/// The wait itself: which update waits, and the check that installs it. One wait at a time.
@MainActor
@Observable
final class YardletUpdateWait {
    /// A build staged by `scripts/stage-update.sh`, or the update Sparkle has ready, which its
    /// installer puts in place once Yardlet quits.
    enum Update: Equatable, Sendable {
        case staged(YardletUpdater.Candidate)
        case sparkle
    }

    /// What the install step reports back.
    enum Outcome: Equatable {
        /// Quitting to install has begun. The build still shows as waiting until the app quits.
        case quitting
        /// A task runs again: go on waiting.
        case keepWaiting
        /// The staged build is no longer the one chosen: stop waiting.
        case stop
    }

    private(set) var update: Update?
    var isWaiting: Bool { update != nil }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var activeTasks: @MainActor () -> Int = { 0 }
    @ObservationIgnored private var install: @MainActor (Update) async -> Outcome = { _ in .stop }
    @ObservationIgnored private var now: @Sendable () -> Date = { Date() }
    @ObservationIgnored private var interval: Duration = YardletUpdateWaitPolicy.checkInterval
    @ObservationIgnored private var quietPeriod: TimeInterval = YardletUpdateWaitPolicy.quietPeriod

    /// Waits for `update` until `activeTasks` has been zero for the quiet period, then calls
    /// `install`. A wait already running is replaced.
    func start(
        _ update: Update,
        activeTasks: @escaping @MainActor () -> Int,
        install: @escaping @MainActor (Update) async -> Outcome,
        now: @escaping @Sendable () -> Date = { Date() },
        interval: Duration = YardletUpdateWaitPolicy.checkInterval,
        quietPeriod: TimeInterval = YardletUpdateWaitPolicy.quietPeriod
    ) {
        task?.cancel()
        self.update = update
        self.activeTasks = activeTasks
        self.install = install
        self.now = now
        self.interval = interval
        self.quietPeriod = quietPeriod
        watch()
    }

    /// The quit to install was refused because a task started at the last moment: wait again.
    func keepWaiting() {
        guard update != nil, task == nil else { return }
        watch()
    }

    /// Cancel Update: the staged build stays staged, for Install Update… later; Sparkle's update
    /// installs when Yardlet quits.
    func cancel() {
        task?.cancel()
        task = nil
        update = nil
    }

    private func watch() {
        task = Task { [weak self] in
            var quietSince: Date?
            while !Task.isCancelled {
                guard let self, let update = self.update else { return }
                switch YardletUpdateWaitPolicy.step(activeTasks: self.activeTasks(), quietSince: quietSince,
                                                    now: self.now(), quietPeriod: self.quietPeriod) {
                case let .wait(since):
                    quietSince = since
                case .install:
                    let outcome = await self.install(update)
                    guard !Task.isCancelled, self.update == update else { return }
                    switch outcome {
                    case .quitting:
                        self.task = nil
                        return
                    case .keepWaiting:
                        quietSince = nil
                    case .stop:
                        self.task = nil
                        self.update = nil
                        return
                    }
                }
                let interval = self.interval
                try? await Task.sleep(for: interval)
            }
        }
    }
}
