import Foundation

enum HarnessProtocolMethodAdmissionError: Error, Equatable, Sendable {
    case missingCapability(
        method: HarnessProtocolMethodID,
        requiresAnyOf: [HarnessCapabilityID]
    )
    case undeclaredExtensionMethod(HarnessProtocolMethodID)
}

enum HarnessProtocolMethodAdmission {
    static func validate(
        _ method: HarnessProtocolMethodID,
        manifest: HarnessAdapterManifest
    ) throws {
        if let required = standardRequirements[method] {
            guard required.contains(where: manifest.supports) else {
                throw HarnessProtocolMethodAdmissionError.missingCapability(
                    method: method,
                    requiresAnyOf: required
                )
            }
            return
        }

        guard manifest.extensionNamespaces.contains(where: { namespace in
            method.rawValue.hasPrefix("\(namespace).")
        }) else {
            throw HarnessProtocolMethodAdmissionError.undeclaredExtensionMethod(method)
        }
    }

    private static let standardRequirements: [HarnessProtocolMethodID: [HarnessCapabilityID]] = [
        .runtimeProbe: [.runtimeDiscovery],
        .catalogRead: [.modelCatalog, .modeCatalog],
        .sessionCreate: [.sessionCreate],
        .sessionResume: [.sessionResume],
        .sessionImport: [.sessionImport],
        .sessionSend: [.turnSend],
        .sessionSteer: [.turnSteer],
        .sessionInterrupt: [.turnInterrupt],
        .permissionRespond: [.structuredPermissions],
        .sessionClose: [.sessionClose]
    ]
}

enum HarnessProtocolHostError: Error, Equatable, Sendable {
    case handshakeTimedOut
    case invalidManifest(HarnessAdapterManifestViolation)
    case negotiationFailed(HarnessProtocolNegotiationError)
    case duplicateHello
    case frameBeforeNegotiation(String)
    case unexpectedReadyFrame
    case wrongVersion(expected: HarnessProtocolVersion, actual: HarnessProtocolVersion)
    case methodNotAdmitted(HarnessProtocolMethodAdmissionError)
    case invalidRequest(HarnessProtocolRequestSchemaError)
    case invalidEvent(HarnessProtocolEventContractViolation)
    case adapterExitedBeforeHandshake(code: Int32?)
    case connectionAlreadyFailed
    case connectionClosed
}

enum HarnessProtocolHostPhase: Equatable, Sendable {
    case awaitingHello(deadline: Date)
    case active(manifest: HarnessAdapterManifest, version: HarnessProtocolVersion)
    case failed(HarnessProtocolHostError)
    case closed
}

enum HarnessProtocolHostAction: Equatable, Sendable {
    case send(HarnessProtocolFrame)
    case acceptedRequest(HarnessProtocolRequest)
    case acceptedResponse(HarnessProtocolResponse)
    case acceptedEvent(HarnessProtocolEventEnvelope)
}

/// Serial state machine for one external adapter connection.
///
/// The future process host will own one instance and feed it decoded JSONL
/// frames before dispatch. Keeping admission separate from I/O makes every
/// fail-closed boundary deterministic and independently testable.
struct HarnessProtocolHostConnection: Sendable {
    private(set) var phase: HarnessProtocolHostPhase
    private let hostVersions: [HarnessProtocolVersion]
    private var eventValidators: [UUID: HarnessProtocolEventContractValidator] = [:]

    init(
        hostVersions: [HarnessProtocolVersion] = HarnessProtocolVersion.hostSupported,
        handshakeTimeout: TimeInterval = 5,
        now: Date = Date()
    ) {
        self.hostVersions = hostVersions
        self.phase = .awaitingHello(deadline: now.addingTimeInterval(max(0, handshakeTimeout)))
    }

    mutating func accept(
        _ frame: HarnessProtocolFrame,
        at now: Date = Date()
    ) throws -> HarnessProtocolHostAction {
        try checkHandshakeDeadline(at: now)

        switch phase {
        case .awaitingHello:
            guard case let .hello(manifest) = frame else {
                return try reject(.frameBeforeNegotiation(frame.kindName))
            }
            do {
                try HarnessAdapterManifestValidator.validate(manifest)
            } catch let violation as HarnessAdapterManifestViolation {
                return try reject(.invalidManifest(violation))
            }

            let version: HarnessProtocolVersion
            do {
                version = try HarnessProtocolNegotiator.negotiate(
                    hostVersions: hostVersions,
                    adapter: manifest
                )
            } catch let error as HarnessProtocolNegotiationError {
                return try reject(.negotiationFailed(error))
            }

            phase = .active(manifest: manifest, version: version)
            return .send(.ready(version))

        case let .active(manifest, selectedVersion):
            switch frame {
            case .hello:
                return try reject(.duplicateHello)
            case .ready:
                return try reject(.unexpectedReadyFrame)
            case let .request(version, request):
                try require(version, selected: selectedVersion)
                do {
                    try HarnessProtocolMethodAdmission.validate(request.method, manifest: manifest)
                } catch let error as HarnessProtocolMethodAdmissionError {
                    return try reject(.methodNotAdmitted(error))
                }
                do {
                    try HarnessProtocolRequestSchema.validate(request, manifest: manifest)
                } catch let error as HarnessProtocolRequestSchemaError {
                    return try reject(.invalidRequest(error))
                }
                return .acceptedRequest(request)
            case let .response(version, response):
                try require(version, selected: selectedVersion)
                return .acceptedResponse(response)
            case let .event(version, event):
                try require(version, selected: selectedVersion)
                var validator = eventValidators[event.localSessionID]
                    ?? HarnessProtocolEventContractValidator(
                        localSessionID: event.localSessionID,
                        manifest: manifest
                    )
                do {
                    try validator.accept(event)
                } catch let error as HarnessProtocolEventContractViolation {
                    return try reject(.invalidEvent(error))
                }
                eventValidators[event.localSessionID] = validator
                return .acceptedEvent(event)
            }

        case .failed:
            throw HarnessProtocolHostError.connectionAlreadyFailed
        case .closed:
            throw HarnessProtocolHostError.connectionClosed
        }
    }

    mutating func checkHandshakeDeadline(at now: Date = Date()) throws {
        guard case let .awaitingHello(deadline) = phase else { return }
        guard now < deadline else {
            return try reject(.handshakeTimedOut)
        }
    }

    mutating func adapterExited(code: Int32?) throws {
        switch phase {
        case .awaitingHello:
            return try reject(.adapterExitedBeforeHandshake(code: code))
        case .active:
            phase = .closed
        case .failed:
            throw HarnessProtocolHostError.connectionAlreadyFailed
        case .closed:
            return
        }
    }

    mutating func close() {
        phase = .closed
    }

    private mutating func require(
        _ actual: HarnessProtocolVersion,
        selected expected: HarnessProtocolVersion
    ) throws {
        guard actual == expected else {
            return try reject(.wrongVersion(expected: expected, actual: actual))
        }
    }

    private mutating func reject<T>(_ error: HarnessProtocolHostError) throws -> T {
        phase = .failed(error)
        throw error
    }
}

private extension HarnessProtocolFrame {
    var kindName: String {
        switch self {
        case .hello: "hello"
        case .ready: "ready"
        case .request: "request"
        case .response: "response"
        case .event: "event"
        }
    }
}
