import Foundation

enum ProviderConnectionService {
    static func snapshot(_ connection: ProviderConnection, executableURL: URL?) async -> HarnessAccountSnapshot {
        guard let descriptor = HarnessCatalog.descriptor(for: connection.harness) else {
            return .unavailable(for: HarnessCatalog.builtIns[0])
        }
        if let home = connection.homePath {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: home, isDirectory: &isDirectory), isDirectory.boolValue else {
                return HarnessAccountSnapshot(id: connection.id, harness: connection.harness, providerID: connection.providerID,
                    state: .actionRequired, accountLabel: connection.name,
                    detail: ProviderConnectionError.invalidBinding.localizedDescription, credentialOwner: descriptor.displayName,
                    checkedAt: Date(), usage: [], canLogin: false, canLogout: false)
            }
        }
        return await HarnessAccountBroker(connection: connection).snapshot(for: descriptor, executableURL: executableURL)
    }
}
