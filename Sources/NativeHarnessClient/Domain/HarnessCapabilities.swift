import Foundation

struct HarnessCapabilities: Codable, Equatable, Sendable {
    var canResume: Bool
    var canInterrupt: Bool
    var hasStructuredPermissions: Bool
    var hasStructuredActivities: Bool
    var hasPlans: Bool
    var acceptsImages: Bool
    var hasSubagents: Bool

    static let unavailable = HarnessCapabilities(
        canResume: false,
        canInterrupt: false,
        hasStructuredPermissions: false,
        hasStructuredActivities: false,
        hasPlans: false,
        acceptsImages: false,
        hasSubagents: false
    )
}

struct HarnessRuntimeDescriptor: Codable, Equatable, Sendable {
    let harness: HarnessKind
    let executableURL: URL
    let version: String
    let capabilities: HarnessCapabilities
    let fingerprint: String
}
