import Foundation
import Observation

/// A build staged by `scripts/stage-update.sh` that is ready to install, for the sidebar's "Restart to
/// update" and its line in the menu bar menu, as the Claude app shows "Relaunch to update" once its
/// update has downloaded. Yardlet looks when the window opens, whenever it comes to the front, and once
/// a minute. Looking checks only that the staged build is this app's and not the installed one; the
/// signature is checked when Install Update… offers it. A build that updates with Sparkle never looks:
/// Sparkle shows its own window for the same.
@MainActor
@Observable
final class YardletStagedUpdate {
    static let checkInterval: Duration = .seconds(60)

    /// The staged build, when there is one to install.
    private(set) var ready: YardletUpdater.Candidate?

    @ObservationIgnored private let root: URL
    @ObservationIgnored private let bundleIdentifier: String?
    @ObservationIgnored private let installedBundle: URL
    @ObservationIgnored private let digests = YardletUpdater.ExecutableDigests()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var isChecking = false

    init(root: URL = YardletUpdater.rootURL, bundleIdentifier: String? = Bundle.main.bundleIdentifier,
         installedBundle: URL = Bundle.main.bundleURL) {
        self.root = root
        self.bundleIdentifier = bundleIdentifier
        self.installedBundle = installedBundle
    }

    /// Looks now and then every `interval`.
    func start(interval: Duration = checkInterval) {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Looks again now, as Yardlet comes to the front; nothing while not started.
    func checkNow() {
        guard task != nil else { return }
        Task { await check() }
    }

    func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        let (root, identifier, installed, digests) = (root, bundleIdentifier, installedBundle, digests)
        let found = await Task.detached(priority: .utility) {
            try? YardletUpdater.pending(root: root, bundleIdentifier: identifier, installedBundle: installed,
                                        digests: digests)
        }.value
        if found != ready { ready = found }
    }
}

extension MenuBarMenu.UpdateLine {
    /// The line for a staged build `ready` to install, while an update waits for tasks or not; nil
    /// without one.
    init?(ready: YardletUpdater.Candidate?, isWaiting: Bool) {
        guard let ready else { return nil }
        self = isWaiting ? .waiting : .ready(build: ready.build)
    }
}
