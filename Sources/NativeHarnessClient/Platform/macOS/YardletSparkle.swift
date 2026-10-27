import AppKit
import Observation
import Sparkle

/// Updates for a public build through Sparkle (README "Updates"): Yardlet › Check for Updates…,
/// Settings › General › Automatically check for updates, and Sparkle's own windows for what it
/// finds. A found update downloads in the background and installs when Yardlet quits. Install and
/// Relaunch asks Yardlet to quit like any other quit; with tasks running the app delegate refuses it
/// and waits for them, as Restart When Tasks Finish does, then quits on its own, and Sparkle's
/// installer, which waits for Yardlet to exit, puts the update in place and opens it again.
///
/// Only a bundle built with a feed URL and the public EdDSA key (`scripts/release.sh` passes them to
/// `build-app.sh`) has an updater. A development build has none: no Sparkle item, no request, and
/// Install Update… for builds staged by `scripts/stage-update.sh` as before.
@MainActor
@Observable
final class YardletSparkle: NSObject, SPUUpdaterDelegate {
    /// Whether a bundle's Info.plist names both the feed and the key its updates are checked against.
    nonisolated static func isConfigured(_ info: [String: Any]?) -> Bool {
        ["SUFeedURL", "SUPublicEDKey"].allSatisfy { key in
            (info?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    /// Check for Updates… is dimmed while Sparkle cannot start a check.
    private(set) var canCheckForUpdates = false
    /// Settings' switch: Sparkle's own setting, on by default (`SUEnableAutomaticChecks`). Off,
    /// Sparkle schedules no check, so Yardlet asks the feed nothing until Check for Updates….
    var checksAutomatically = false {
        didSet {
            guard let updater = controller?.updater, updater.automaticallyChecksForUpdates != checksAutomatically
            else { return }
            updater.automaticallyChecksForUpdates = checksAutomatically
        }
    }

    /// Sparkle is about to ask Yardlet to quit, to install the update and open it again.
    @ObservationIgnored var willRelaunch: () -> Void = {}
    /// Sparkle's update session ended: nothing found, installed later on quit, cancelled or failed.
    @ObservationIgnored var updateCycleEnded: () -> Void = {}

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// Nil unless `info` (the app's Info.plist) is configured for Sparkle.
    init?(info: [String: Any]? = Bundle.main.infoDictionary) {
        guard Self.isConfigured(info) else { return nil }
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self,
                                                  userDriverDelegate: nil)
    }

    /// Starts Sparkle once the app has launched: from here on it checks on its schedule.
    func start() {
        guard let controller, observations.isEmpty else { return }
        controller.startUpdater()
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
                MainActor.assumeIsolated { self?.canCheckForUpdates = change.newValue ?? false }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, change in
                MainActor.assumeIsolated { self?.checksAutomatically = change.newValue ?? false }
            },
        ]
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    // MARK: - SPUUpdaterDelegate

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        willRelaunch()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        updateCycleEnded()
    }
}
