import Foundation
import Security
import YardletRemote

/// The Mac's remote keys (docs/REMOTE_PROTOCOL.md §11.2) as one generic password in the login keychain:
/// service `<bundle identifier>.remote`, account `identity`. An item the app adds trusts the app's
/// designated requirement, so another program cannot read it without asking.
struct KeychainRemoteIdentityStore: RemoteIdentityStoring {
    let service: String

    static func live(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? YardletProduct.bundleIdentifier) -> Self {
        KeychainRemoteIdentityStore(service: "\(bundleIdentifier).remote")
    }

    private var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "identity"]
    }

    func load() throws -> RemoteIdentity? {
        var search = query
        search[kSecReturnData] = true
        search[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return try RemoteIdentity(stored: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    func save(_ identity: RemoteIdentity) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: identity.stored] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = identity.stored
            item[kSecAttrLabel] = "Yardlet remote"
            item[kSecAttrDescription] = "Yardlet phone remote keys"
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    struct KeychainError: Error {
        var status: OSStatus
    }
}
