import Foundation

/// The original provider identity and its saved storage/account binding, retained together
/// when editing maps a new native conversation onto the same Yardlet chat.
struct NativeConversationOrigin: Codable, Hashable, Sendable {
    let harness: HarnessKind
    let providerSessionID: String
    let environmentScope: SessionEnvironmentScope
    let connection: ProviderConnection?
    let workspaceURL: URL
    let runtimeExecutableURL: URL
    let title: String
    let providerOptions: [String: String]
    let projectID: UUID?
    let additionalRoots: [String]

    init?(session: SessionRecord) {
        guard let providerID = session.providerSessionID, !providerID.isEmpty else { return nil }
        harness = session.harness
        providerSessionID = providerID
        environmentScope = session.environmentScope
        connection = session.connection
        workspaceURL = session.workspaceURL
        runtimeExecutableURL = session.runtimeExecutableURL
        title = session.title
        providerOptions = session.providerOptions
        projectID = session.projectID
        additionalRoots = session.additionalRoots
    }

    func matches(_ session: SessionRecord) -> Bool {
        session.harness == harness && session.providerSessionID == providerSessionID
            && session.environmentScope == environmentScope && session.connection == connection
            && session.workspaceURL == workspaceURL
    }

    var record: SessionRecord {
        SessionRecord(harness: harness, workspaceURL: workspaceURL,
            runtimeExecutableURL: runtimeExecutableURL, title: title,
            providerSessionID: providerSessionID, providerOptions: providerOptions,
            environmentScope: environmentScope, connection: connection,
            projectID: projectID, additionalRoots: additionalRoots)
    }
}
