import Foundation

/// A harness-neutral composer submission. Text always travels; local image attachments and file
/// mentions keep their own slots instead of being flattened into the prompt up front, so an
/// adapter whose protocol carries them can send them and one whose protocol cannot can refuse
/// instead of silently dropping them.
struct HarnessUserInput: Equatable, Sendable {
    struct ImageAttachment: Equatable, Sendable {
        let url: URL
        let mimeType: String

        init(url: URL, mimeType: String) {
            self.url = url.standardizedFileURL
            self.mimeType = mimeType
        }

        init?(url: URL) {
            guard let mimeType = HarnessUserInput.imageMIMEType(for: url) else { return nil }
            self.init(url: url, mimeType: mimeType)
        }
    }

    /// One attachment already read off disk. Adapters share the same encoding so a fixture can
    /// pin the wire shape without touching the file system.
    struct EncodedImage: Equatable, Sendable {
        let mimeType: String
        let base64Data: String
    }

    var text: String
    var images: [ImageAttachment]
    var mentions: [URL]

    init(text: String, images: [ImageAttachment] = [], mentions: [URL] = []) {
        self.text = text
        self.images = images
        self.mentions = mentions.map(\.standardizedFileURL)
    }

    var hasAttachments: Bool { !images.isEmpty || !mentions.isEmpty }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasAttachments
    }

    /// Only Codex has a provider-owned mention envelope. Every other protocol gets one fixed
    /// projection — the prompt, then one `@<absolute path>` line per mention — so adapters do
    /// not each invent a separator. Text-only input is unchanged by this rule.
    var promptText: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mentions.isEmpty else { return trimmed }
        let lines = mentions.map { "@\($0.path(percentEncoded: false))" }
        return ([trimmed].filter { !$0.isEmpty } + lines).joined(separator: "\n")
    }

    /// The images the conversation shows with this request, so a sent attachment is not invisible
    /// in the transcript. The request's text is `promptText`.
    var transcriptImages: [TranscriptImageAttachment] {
        images.map { TranscriptImageAttachment(url: $0.url) }
    }

    /// Reads every attachment once, at send time, in the adapter that is about to transmit it.
    func encodedImages() throws -> [EncodedImage] {
        try images.map { attachment in
            if attachment.url.scheme == "data" {
                guard let image = InlineImageInput.image(from: attachment.url), image.mimeType == attachment.mimeType else {
                    throw HarnessAdapterError.capabilityUnavailable(L10n.string("The saved image attachment is unavailable."))
                }
                return image
            }
            guard let data = try? Data(contentsOf: attachment.url) else {
                throw HarnessAdapterError.attachmentUnreadable(attachment.url)
            }
            return EncodedImage(
                mimeType: attachment.mimeType,
                base64Data: data.base64EncodedString()
            )
        }
    }

    /// The picker admits only extensions with an unambiguous image media type. Anything else has
    /// no honest `media_type`/`mimeType` to declare, so it is not an image attachment.
    static func imageMIMEType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "heic": "image/heic"
        case "heif": "image/heif"
        case "tif", "tiff": "image/tiff"
        default: nil
        }
    }
}

extension HarnessUserInput {
    /// What a shared composer draft becomes on the neutral boundary. Inputs with no neutral
    /// representation (audio, skills, remote media, provider-owned envelopes) are reported
    /// rather than dropped, so the composer can say so instead of sending less than was attached.
    struct Projection: Equatable, Sendable {
        var input: HarnessUserInput
        var unsupported: [CodexUserInput]

        var carriesEverything: Bool { unsupported.isEmpty }
    }

    /// Projects the shared Codex-shaped composer draft onto the harness-neutral input.
    static func projecting(_ draft: CodexComposerDraft) -> Projection {
        var text: [String] = []
        var images: [ImageAttachment] = []
        var mentions: [URL] = []
        var unsupported: [CodexUserInput] = []
        for input in draft.inputs {
            switch input {
            case let .text(value, _):
                text.append(value)
            case let .localImage(url, _):
                if let attachment = ImageAttachment(url: url) {
                    images.append(attachment)
                } else {
                    unsupported.append(input)
                }
            case let .mention(_, path):
                mentions.append(path)
            case let .image(url, _):
                if let image = InlineImageInput.image(from: url) {
                    images.append(.init(url: url, mimeType: image.mimeType))
                } else { unsupported.append(input) }
            case .audio, .localAudio, .skill, .unknown:
                unsupported.append(input)
            }
        }
        return Projection(
            input: HarnessUserInput(
                text: text.joined(separator: "\n"),
                images: images,
                mentions: mentions
            ),
            unsupported: unsupported
        )
    }
}
