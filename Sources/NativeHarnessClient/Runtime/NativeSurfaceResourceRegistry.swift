import Foundation

/// App-owned native surfaces that can outlive a SwiftUI body while the application is
/// deciding whether it may terminate. The registry is intentionally weak: a surface remains
/// owned by its task or task view, while the application gets one bounded termination hook
/// for both visible and hidden surfaces when the user confirms Quit.
@MainActor
final class NativeSurfaceResourceRegistry {
    static let shared = NativeSurfaceResourceRegistry()

    private final class WeakResource {
        weak var value: (any NativeSurfaceResource)?

        init(_ value: any NativeSurfaceResource) {
            self.value = value
        }
    }

    private var resources: [ObjectIdentifier: WeakResource] = [:]

    func register(_ resource: any NativeSurfaceResource) {
        resources[ObjectIdentifier(resource)] = WeakResource(resource)
        pruneReleasedResources()
    }

    /// Stop every retained native surface and discard released weak entries. The call is
    /// idempotent so the app delegate can safely invoke it during a repeated terminate callback.
    func stopAll() {
        pruneReleasedResources()
        for resource in resources.values.compactMap(\.value) {
            resource.terminateForApplicationShutdown()
        }
        pruneReleasedResources()
    }

    private func pruneReleasedResources() {
        resources = resources.filter { $0.value.value != nil }
    }
}

@MainActor
protocol NativeSurfaceResource: AnyObject {
    func stop()
    func terminateForApplicationShutdown()
}
