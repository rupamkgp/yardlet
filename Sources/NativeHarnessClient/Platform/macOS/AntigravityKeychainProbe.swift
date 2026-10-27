import Foundation
import Security

extension HarnessAccountBroker {
    /// Antigravity stores its browser OAuth profile in the native keyring. Query only
    /// the stable item identity; never request or serialize the credential value.
    static func antigravityCredentialState(keychainStatus: OSStatus? = nil) -> AccountAuthState {
        let status = keychainStatus ?? SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "gemini",
            kSecAttrAccount: "antigravity",
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: false
        ] as CFDictionary, nil)
        switch status {
        case errSecSuccess: return .signedIn
        case errSecItemNotFound: return .signedOut
        default: return .unknown
        }
    }
}
