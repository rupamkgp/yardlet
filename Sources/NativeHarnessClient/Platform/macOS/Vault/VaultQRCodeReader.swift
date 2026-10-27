import Foundation
import Vision

/// The QR codes in an image, read with Vision on this Mac: a page's screenshot (a site's two-factor
/// setup) or a picture of an authenticator app's export (docs/BROWSER_VAULT_DESIGN.md §14).
enum VaultQRCodeReader {
    static func messages(in image: Data) -> [String] {
        messages(VNImageRequestHandler(data: image, options: [:]))
    }

    static func messages(in file: URL) -> [String] {
        messages(VNImageRequestHandler(url: file, options: [:]))
    }

    /// The two-factor codes in images, and how many accounts in them Yardlet cannot keep.
    static func setups(in messages: [String]) -> (setups: [OneTimeCodeSetup], unsupported: Int) {
        messages.reduce(into: ([OneTimeCodeSetup](), 0)) { found, message in
            let codes = OneTimeCodeSetup.setups(in: message)
            for setup in codes.setups where !found.0.contains(where: { $0.secret.key == setup.secret.key }) {
                found.0.append(setup)
            }
            found.1 += codes.unsupported
        }
    }

    private static func messages(_ handler: VNImageRequestHandler) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? handler.perform([request])
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }
}
