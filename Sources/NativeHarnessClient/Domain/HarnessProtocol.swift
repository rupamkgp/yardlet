import Foundation

/// A negotiated Yardlet Harness Protocol version.
///
/// Major versions are incompatible. Minor versions only add optional methods,
/// capabilities, or fields; an adapter must advertise every minor version it
/// can actually decode rather than relying on an implicit fallback.
struct HarnessProtocolVersion: Codable, Comparable, CustomStringConvertible, Hashable, Sendable {
    let major: UInt16
    let minor: UInt16

    static let v1 = HarnessProtocolVersion(major: 1, minor: 0)
    static let hostSupported: [HarnessProtocolVersion] = [.v1]

    var description: String { "\(major).\(minor)" }

    static func < (lhs: HarnessProtocolVersion, rhs: HarnessProtocolVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }
}

struct HarnessCapabilityID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static let runtimeDiscovery = Self(rawValue: "runtime.discovery")
    static let modelCatalog = Self(rawValue: "catalog.models")
    static let modeCatalog = Self(rawValue: "catalog.modes")
    static let sessionCreate = Self(rawValue: "session.create")
    static let sessionResume = Self(rawValue: "session.resume")
    static let sessionImport = Self(rawValue: "session.import")
    static let sessionClose = Self(rawValue: "session.close")
    static let turnSend = Self(rawValue: "turn.send")
    static let turnSteer = Self(rawValue: "turn.steer")
    static let turnInterrupt = Self(rawValue: "turn.interrupt")
    static let structuredPermissions = Self(rawValue: "permission.structured")
    static let streaming = Self(rawValue: "timeline.streaming")
    static let reasoning = Self(rawValue: "timeline.reasoning")
    static let structuredActivities = Self(rawValue: "timeline.activities")
    static let plans = Self(rawValue: "timeline.plans")
    static let images = Self(rawValue: "input.images")
    static let usage = Self(rawValue: "timeline.usage")
    static let subagents = Self(rawValue: "timeline.subagents")
}

struct HarnessAdapterManifest: Codable, Equatable, Sendable {
    let adapterID: String
    let harness: HarnessKind
    let displayName: String
    let protocolVersions: [HarnessProtocolVersion]
    let capabilities: [HarnessCapabilityID]
    let extensionNamespaces: [String]

    init(
        adapterID: String,
        harness: HarnessKind,
        displayName: String,
        protocolVersions: [HarnessProtocolVersion],
        capabilities: [HarnessCapabilityID],
        extensionNamespaces: [String] = []
    ) {
        self.adapterID = adapterID
        self.harness = harness
        self.displayName = displayName
        self.protocolVersions = Array(Set(protocolVersions)).sorted(by: >)
        self.capabilities = Array(Set(capabilities)).sorted { $0.rawValue < $1.rawValue }
        self.extensionNamespaces = Array(Set(extensionNamespaces)).sorted()
    }

    func supports(_ capability: HarnessCapabilityID) -> Bool {
        capabilities.contains(capability)
    }
}

enum HarnessProtocolNegotiationError: Error, Equatable, Sendable {
    case emptyHostVersionSet
    case emptyAdapterVersionSet(adapterID: String)
    case incompatibleVersions(host: [HarnessProtocolVersion], adapter: [HarnessProtocolVersion])
}

extension HarnessProtocolNegotiationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .emptyHostVersionSet:
            "Yardlet did not advertise a harness protocol version."
        case let .emptyAdapterVersionSet(adapterID):
            "Harness adapter \(adapterID) did not advertise a protocol version."
        case let .incompatibleVersions(host, adapter):
            "Harness protocol versions are incompatible (Yardlet: \(host), adapter: \(adapter))."
        }
    }
}

enum HarnessProtocolNegotiator {
    static func negotiate(
        hostVersions: [HarnessProtocolVersion] = HarnessProtocolVersion.hostSupported,
        adapter manifest: HarnessAdapterManifest
    ) throws -> HarnessProtocolVersion {
        guard !hostVersions.isEmpty else {
            throw HarnessProtocolNegotiationError.emptyHostVersionSet
        }
        guard !manifest.protocolVersions.isEmpty else {
            throw HarnessProtocolNegotiationError.emptyAdapterVersionSet(
                adapterID: manifest.adapterID
            )
        }

        let adapterVersions = Set(manifest.protocolVersions)
        guard let selected = Set(hostVersions).intersection(adapterVersions).max() else {
            throw HarnessProtocolNegotiationError.incompatibleVersions(
                host: hostVersions.sorted(by: >),
                adapter: manifest.protocolVersions
            )
        }
        return selected
    }
}

enum HarnessAdapterManifestViolation: Error, Equatable, Sendable {
    case emptyAdapterID
    case emptyDisplayName
    case missingProtocolVersions
    case missingRequiredCapability(HarnessCapabilityID)
    case invalidCapabilityID(String)
    case invalidExtensionNamespace(String)
}

enum HarnessAdapterManifestValidator {
    static let requiredCapabilities: Set<HarnessCapabilityID> = [
        .runtimeDiscovery,
        .sessionCreate,
        .sessionClose,
        .turnSend,
        .streaming
    ]

    static func validate(_ manifest: HarnessAdapterManifest) throws {
        guard !manifest.adapterID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HarnessAdapterManifestViolation.emptyAdapterID
        }
        guard !manifest.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HarnessAdapterManifestViolation.emptyDisplayName
        }
        guard !manifest.protocolVersions.isEmpty else {
            throw HarnessAdapterManifestViolation.missingProtocolVersions
        }

        let advertised = Set(manifest.capabilities)
        for capability in requiredCapabilities where !advertised.contains(capability) {
            throw HarnessAdapterManifestViolation.missingRequiredCapability(capability)
        }
        for capability in manifest.capabilities where !isNamespaced(capability.rawValue) {
            throw HarnessAdapterManifestViolation.invalidCapabilityID(capability.rawValue)
        }
        for namespace in manifest.extensionNamespaces where !isNamespaced(namespace) {
            throw HarnessAdapterManifestViolation.invalidExtensionNamespace(namespace)
        }
    }

    private static func isNamespaced(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        return components.count >= 2 && components.allSatisfy { component in
            !component.isEmpty && component.allSatisfy { character in
                character.isLetter || character.isNumber || character == "-" || character == "_"
            }
        }
    }
}

/// Opt-in bridge for adapters that have migrated to the versioned contract.
/// Existing `HarnessAdapter` implementations remain source-compatible while
/// migration proceeds one transport family at a time.
protocol VersionedHarnessAdapter: HarnessAdapter {
    nonisolated var protocolManifest: HarnessAdapterManifest { get }
}

extension HarnessCapabilities {
    func protocolCapabilities() -> [HarnessCapabilityID] {
        var result: Set<HarnessCapabilityID> = [
            .runtimeDiscovery,
            .sessionCreate,
            .sessionClose,
            .turnSend,
            .streaming
        ]
        if canResume { result.insert(.sessionResume) }
        if canInterrupt { result.insert(.turnInterrupt) }
        if hasStructuredPermissions { result.insert(.structuredPermissions) }
        if hasStructuredActivities { result.insert(.structuredActivities) }
        if hasPlans { result.insert(.plans) }
        if acceptsImages { result.insert(.images) }
        if hasSubagents { result.insert(.subagents) }
        return result.sorted { $0.rawValue < $1.rawValue }
    }
}
