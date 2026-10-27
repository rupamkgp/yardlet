import Foundation
import Security

/// Connector credentials as generic passwords in the login keychain, one item per connector:
/// service `<bundle identifier>.connectors`, account the connector's ID. The app's designated
/// requirement stays the same across ad-hoc rebuilds (scripts/build-app.sh), so an update keeps
/// access without a keychain prompt; a QA bundle's own identifier keeps its items apart.
struct KeychainConnectorCredentialStore: ConnectorCredentialStoring {
    struct KeychainError: Error, LocalizedError {
        var status: OSStatus

        var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return L10n.format("The keychain refused the connector's credential: %@", message)
        }
    }

    let service: String

    static func live(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? YardletProduct.bundleIdentifier) -> Self {
        KeychainConnectorCredentialStore(service: "\(bundleIdentifier).connectors")
    }

    private func query(_ id: UUID) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: id.uuidString
        ]
    }

    func load(_ id: UUID) throws -> ConnectorCredential? {
        var search = query(id)
        search[kSecReturnData] = true
        search[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return try JSONDecoder().decode(ConnectorCredential.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    func save(_ credential: ConnectorCredential, for id: UUID) throws {
        let data = try JSONEncoder().encode(credential)
        let status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(id)
            item[kSecValueData] = data
            item[kSecAttrLabel] = "Yardlet connector"
            item[kSecAttrDescription] = "Yardlet connector credential"
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    func delete(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
