import Foundation
import Network

/// Tells the app model when this Mac's network path comes and goes, as the system reports it
/// (`NWPathMonitor`), so a turn a lost connection cut off continues once the network is back
/// (`AppModel.networkPathChanged`). A Mac waking from sleep reports its path again.
@MainActor final class NetworkWatch {
    private var monitor: NWPathMonitor?

    func start(reporting model: AppModel) {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak model] path in
            let isSatisfied = path.status == .satisfied
            Task { @MainActor in model?.networkPathChanged(isSatisfied: isSatisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "yardlet.network.paths"))
        self.monitor = monitor
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }
}
