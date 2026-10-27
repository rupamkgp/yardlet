import CryptoKit
import Foundation

/// ES256 with CryptoKit's P-256, for App Store Connect's tokens (`ES256Signing`).
struct MacES256Signer: ES256Signing {
    func isPrivateKey(_ pem: String) -> Bool {
        (try? P256.Signing.PrivateKey(pemRepresentation: pem)) != nil
    }

    func sign(_ message: Data, withPrivateKey pem: String) throws -> Data {
        try P256.Signing.PrivateKey(pemRepresentation: pem).signature(for: message).rawRepresentation
    }
}
