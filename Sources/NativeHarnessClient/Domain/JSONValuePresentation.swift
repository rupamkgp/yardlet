import Foundation

extension JSONValue {
    /// Readable text for a tool card. A provider string is shown as the provider wrote it; a
    /// structured value is pretty printed so arguments and results stay legible.
    var readableText: String? {
        switch self {
        case .null:
            return nil
        case let .string(value):
            return value.isEmpty ? nil : value
        case let .object(object) where object.isEmpty:
            return nil
        case let .array(values) where values.isEmpty:
            return nil
        default:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(self) else { return nil }
            let text = String(decoding: data, as: UTF8.self)
            return text.isEmpty ? nil : text
        }
    }

    /// Concatenated text of a provider content array, accepting both a bare string and the
    /// `[{"type": "text", "text": …}]` shape every harness in this repository uses.
    var contentText: String? {
        if case let .string(value) = self { return value.isEmpty ? nil : value }
        guard case let .array(values) = self else { return nil }
        let chunks = values.compactMap { block -> String? in
            if case let .string(value) = block { return value }
            guard block["type"]?.stringValue == "text" else { return nil }
            return block["text"]?.stringValue
        }
        let text = chunks.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    /// The inline images of a provider content array, at most eight as the Claude app previews a
    /// call's screenshots: Claude's `{"type": "image", "source": {"type": "base64", …}}` and MCP's
    /// `{"type": "image", "data": …, "mimeType": …}`. An image by URL is never fetched and is left out.
    var contentImages: [TranscriptImageAttachment]? {
        guard case let .array(values) = self else { return nil }
        var images: [TranscriptImageAttachment] = []
        for block in values where images.count < 8 && block["type"]?.stringValue == "image" {
            let source = block["source"]
            let mimeType = source?["media_type"]?.stringValue ?? block["mimeType"]?.stringValue
            let data = source?["type"]?.stringValue == "base64" ? source?["data"]?.stringValue : block["data"]?.stringValue
            guard let mimeType, let data, let url = InlineImageInput.url(mimeType: mimeType, base64: data) else { continue }
            images.append(TranscriptImageAttachment(url: url, name: nil))
        }
        return images.isEmpty ? nil : images
    }
}
