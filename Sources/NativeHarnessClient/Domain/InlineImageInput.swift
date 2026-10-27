import Foundation

/// Immutable image bytes already owned by a saved conversation. No download, local-file
/// replacement, transcoding or provider-home migration is involved in restoring this input.
enum InlineImageInput {
    static let maximumBytes = 8 * 1_048_576
    private static let mediaTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    static func url(mimeType: String, base64: String) -> URL? {
        guard mediaTypes.contains(mimeType), !base64.isEmpty,
              base64.utf8.count <= (maximumBytes + 2) / 3 * 4,
              let bytes = Data(base64Encoded: base64), !bytes.isEmpty, bytes.count <= maximumBytes else { return nil }
        return URL(string: "data:\(mimeType);base64,\(bytes.base64EncodedString())")
    }

    static func image(from url: URL) -> HarnessUserInput.EncodedImage? {
        guard url.scheme == "data" else { return nil }
        let text = url.absoluteString
        guard let separator = text.firstIndex(of: ",") else { return nil }
        let header = String(text[text.index(text.startIndex, offsetBy: 5)..<separator])
        guard header.hasSuffix(";base64") else { return nil }
        let mimeType = String(header.dropLast(7))
        let base64 = String(text[text.index(after: separator)...])
        guard let canonical = self.url(mimeType: mimeType, base64: base64) else { return nil }
        let canonicalText = canonical.absoluteString
        return .init(mimeType: mimeType, base64Data: String(canonicalText.dropFirst("data:\(mimeType);base64,".count)))
    }
}
