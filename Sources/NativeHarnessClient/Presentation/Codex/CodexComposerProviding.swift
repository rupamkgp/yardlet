import Foundation

/// The selected App Server `UserInput` union. Keeping the wire cases typed prevents the shared
/// composer from silently flattening images, skills, mentions, or future input variants into text.
enum CodexUserInput: Codable, Equatable, Sendable {
    case text(String, textElements: [CodexTextElement] = [])
    case image(URL, detail: CodexImageDetail? = nil)
    case localImage(URL, detail: CodexImageDetail? = nil)
    case audio(URL)
    case localAudio(URL)
    case skill(name: String, path: URL)
    case mention(name: String, path: URL)
    case unknown(JSONValue)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case textElements = "text_elements"
        case url
        case path
        case detail
        case name
        case raw
    }

    init(from decoder: Decoder) throws {
        // Decode the complete JSON envelope first. A keyed container's superDecoder can lose
        // unknown sibling keys on some Foundation codecs, which would violate the forward-
        // compatibility contract for queued drafts. Retaining the JSON value also lets unknown
        // future variants round-trip byte-for-byte at the semantic JSON level.
        let raw = try JSONValue(from: decoder)
        guard case let .object(object) = raw,
              let type = object["type"]?.stringValue else {
            self = .unknown(raw)
            return
        }
        switch type {
        case "text":
            self = .text(
                try Self.decode(String.self, from: object["text"]),
                textElements: try Self.decodeIfPresent(
                    [CodexTextElement].self,
                    from: object["text_elements"]
                ) ?? []
            )
        case "image":
            self = .image(
                try Self.decode(URL.self, from: object["url"]),
                detail: try Self.decodeIfPresent(CodexImageDetail.self, from: object["detail"])
            )
        case "localImage":
            self = .localImage(
                try Self.decode(URL.self, from: object["path"]),
                detail: try Self.decodeIfPresent(CodexImageDetail.self, from: object["detail"])
            )
        case "audio":
            self = .audio(try Self.decode(URL.self, from: object["url"]))
        case "localAudio":
            self = .localAudio(try Self.decode(URL.self, from: object["path"]))
        case "skill":
            self = .skill(
                name: try Self.decode(String.self, from: object["name"]),
                path: try Self.decode(URL.self, from: object["path"])
            )
        case "mention":
            self = .mention(
                name: try Self.decode(String.self, from: object["name"]),
                path: try Self.decode(URL.self, from: object["path"])
            )
        default:
            self = .unknown(raw)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue?) throws -> T {
        guard let value else {
            throw DecodingError.keyNotFound(
                CodingKeys.type,
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Missing Codex user input value"
                )
            )
        }
        return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private static func decodeIfPresent<T: Decodable>(
        _ type: T.Type,
        from value: JSONValue?
    ) throws -> T? {
        guard let value else { return nil }
        return try decode(type, from: value)
    }

    func encode(to encoder: Encoder) throws {
        // Forward-compatible inputs must remain lossless when a queued draft is persisted.
        // Encoding an unknown envelope as `{type: "unknown", raw: ...}` would make a later
        // resume submit a different wire shape, so write the retained provider payload directly.
        if case let .unknown(raw) = self {
            try raw.encode(to: encoder)
            return
        }

        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text, textElements):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encode(textElements, forKey: .textElements)
        case let .image(url, detail):
            try container.encode("image", forKey: .type)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(detail, forKey: .detail)
        case let .localImage(url, detail):
            try container.encode("localImage", forKey: .type)
            try container.encode(url, forKey: .path)
            try container.encodeIfPresent(detail, forKey: .detail)
        case let .audio(url):
            try container.encode("audio", forKey: .type)
            try container.encode(url, forKey: .url)
        case let .localAudio(url):
            try container.encode("localAudio", forKey: .type)
            try container.encode(url, forKey: .path)
        case let .skill(name, path):
            try container.encode("skill", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(path, forKey: .path)
        case let .mention(name, path):
            try container.encode("mention", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(path, forKey: .path)
        case .unknown:
            // Handled above so the compiler keeps this switch exhaustive if another case is
            // added later.
            break
        }
    }

    var jsonValue: JSONValue {
        switch self {
        case let .text(text, textElements):
            var value: [String: JSONValue] = [
                "type": .string("text"),
                "text": .string(text)
            ]
            if !textElements.isEmpty {
                value["text_elements"] = .array(textElements.map(\.jsonValue))
            }
            return .object(value)
        case let .image(url, detail):
            return imageValue(type: "image", urlKey: "url", url: url, detail: detail)
        case let .localImage(url, detail):
            return imageValue(type: "localImage", urlKey: "path", url: url, detail: detail)
        case let .audio(url):
            return .object(["type": .string("audio"), "url": .string(url.absoluteString)])
        case let .localAudio(url):
            return .object(["type": .string("localAudio"), "path": .string(url.path(percentEncoded: false))])
        case let .skill(name, path):
            return .object([
                "type": .string("skill"),
                "name": .string(name),
                "path": .string(path.path(percentEncoded: false))
            ])
        case let .mention(name, path):
            return .object([
                "type": .string("mention"),
                "name": .string(name),
                "path": .string(path.path(percentEncoded: false))
            ])
        case let .unknown(raw):
            return raw
        }
    }

    private func imageValue(
        type: String,
        urlKey: String,
        url: URL,
        detail: CodexImageDetail?
    ) -> JSONValue {
        var value: [String: JSONValue] = [
            "type": .string(type),
            urlKey: .string(
                type == "localImage"
                    ? url.path(percentEncoded: false)
                    : url.absoluteString
            )
        ]
        if let detail { value["detail"] = .string(detail.rawValue) }
        return .object(value)
    }
}

struct CodexTextElement: Codable, Equatable, Sendable {
    let start: Int64
    let end: Int64
    let placeholder: String?

    init(start: Int64, end: Int64, placeholder: String? = nil) {
        self.start = start
        self.end = end
        self.placeholder = placeholder
    }

    private enum CodingKeys: String, CodingKey {
        case byteRange
        case placeholder
    }

    private enum ByteRangeKeys: String, CodingKey {
        case start
        case end
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let byteRange = try container.nestedContainer(
            keyedBy: ByteRangeKeys.self,
            forKey: .byteRange
        )
        start = try byteRange.decode(Int64.self, forKey: .start)
        end = try byteRange.decode(Int64.self, forKey: .end)
        placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var byteRange = container.nestedContainer(keyedBy: ByteRangeKeys.self, forKey: .byteRange)
        try byteRange.encode(start, forKey: .start)
        try byteRange.encode(end, forKey: .end)
        try container.encodeIfPresent(placeholder, forKey: .placeholder)
    }

    var jsonValue: JSONValue {
        var value: [String: JSONValue] = [
            "byteRange": .object([
                "start": .integer(start),
                "end": .integer(end)
            ])
        ]
        if let placeholder { value["placeholder"] = .string(placeholder) }
        return .object(value)
    }
}

enum CodexImageDetail: String, Codable, Equatable, Sendable {
    case auto
    case low
    case high
    case original
}

/// The native picker only admits inputs that have an exact App Server envelope. Remote URLs are
/// still representable by `CodexUserInput.image`/`audio`, but the local picker intentionally does
/// not fetch or transmit them on the user's behalf.
enum CodexLocalAttachmentKind: Equatable, Sendable {
    case image
    case audio
    case unsupported
}

enum CodexRemoteAttachmentKind: Equatable, Sendable {
    case image
    case audio
}

extension CodexUserInput {
    static func localAttachmentKind(for url: URL) -> CodexLocalAttachmentKind {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff":
            return .image
        case "wav", "mp3", "m4a", "aac", "flac", "ogg":
            return .audio
        default:
            return .unsupported
        }
    }

    static func localAttachment(for url: URL) -> CodexUserInput? {
        switch localAttachmentKind(for: url) {
        case .image:
            return .localImage(url.standardizedFileURL, detail: .auto)
        case .audio:
            return .localAudio(url.standardizedFileURL)
        case .unsupported:
            return nil
        }
    }

    static func localMention(for url: URL) -> CodexUserInput? {
        let standardizedURL = url.standardizedFileURL
        guard standardizedURL.isFileURL else { return nil }
        let name = standardizedURL.lastPathComponent.isEmpty
            ? standardizedURL.path(percentEncoded: false)
            : standardizedURL.lastPathComponent
        guard !name.isEmpty else { return nil }
        return .mention(name: name, path: standardizedURL)
    }

    static func remoteAttachment(
        for rawValue: String,
        kind: CodexRemoteAttachmentKind
    ) -> CodexUserInput? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              !url.isFileURL else { return nil }
        switch kind {
        case .image:
            return .image(url, detail: .auto)
        case .audio:
            return .audio(url)
        }
    }
}

struct CodexComposerDraft: Codable, Equatable, Sendable {
    var inputs: [CodexUserInput]

    init(inputs: [CodexUserInput] = []) {
        self.inputs = inputs
    }

    var isEmpty: Bool {
        inputs.isEmpty || inputs.allSatisfy {
            if case let .text(value, _) = $0 {
                return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return false
        }
    }

    var text: String {
        inputs.compactMap { input in
            guard case let .text(value, _) = input else { return nil }
            return value
        }.joined(separator: "\n")
    }

    /// The images the message carries, in the order a harness sends them.
    var imageURLs: [URL] { inputs.compactMap(Self.imageURL(of:)) }

    static func imageURL(of input: CodexUserInput) -> URL? {
        switch input {
        case let .localImage(url, _): url.standardizedFileURL
        case let .image(url, _): url
        default: nil
        }
    }

    func removingInput(at index: Int) -> CodexComposerDraft {
        guard inputs.indices.contains(index) else { return self }
        var copy = self
        copy.inputs.remove(at: index)
        return copy
    }
}

extension CodexUserInput {
    /// Decode one provider-owned user-input envelope without inventing a fallback wire shape.
    /// Unknown future variants retain their exact JSON envelope; malformed known variants return nil.
    static func decode(_ value: JSONValue) -> CodexUserInput? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(CodexUserInput.self, from: data)
    }
}

extension CodexUserMessageItem {
    /// A compact, human-readable projection for the conversation surface. Provider input
    /// envelopes remain typed in storage and on the wire; only their visible labels are flattened.
    var displayText: String {
        let inputs = content.compactMap(CodexUserInput.decode)
        // The Codex app shows its implement request as the choice that sent it.
        if inputs.count == 1, case let .text(value, _) = inputs[0], CodexPlanImplementation.isRequest(value) {
            return L10n.string("Yes, implement this plan")
        }
        return inputs.compactMap(Self.label(for:))
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// The message as its bubble shows it: the text with its skill and mention labels, and the images
    /// previewed beside that text. Image envelopes are read directly, so an inline image is not
    /// re-encoded through the generic input decoder every time the timeline draws.
    var sentContent: (text: String, images: [TranscriptImageAttachment]) {
        var labels: [String] = []
        var images: [TranscriptImageAttachment] = []
        for value in content {
            switch value["type"]?.stringValue {
            case "image":
                if let url = value["url"]?.stringValue.flatMap(URL.init(string:)) {
                    images.append(TranscriptImageAttachment(url: url))
                }
            case "localImage":
                if let path = value["path"]?.stringValue, !path.isEmpty {
                    images.append(TranscriptImageAttachment(url: URL(filePath: path)))
                }
            default:
                guard let input = CodexUserInput.decode(value) else { continue }
                if content.count == 1, case let .text(text, _) = input, CodexPlanImplementation.isRequest(text) {
                    return (L10n.string("Yes, implement this plan"), [])
                }
                if let label = Self.label(for: input), !label.isEmpty { labels.append(label) }
            }
        }
        return (labels.joined(separator: "\n"), images)
    }

    private static func label(for input: CodexUserInput) -> String? {
        switch input {
        case let .text(value, _):
            value
        case let .image(url, _):
            url.scheme == "data" ? L10n.string("Image") : url.absoluteString
        case let .audio(url):
            url.absoluteString
        case let .localImage(url, _), let .localAudio(url):
            url.lastPathComponent
        case let .skill(name, _):
            "$\(name)"
        case let .mention(name, _):
            "@\(name)"
        case .unknown:
            nil
        }
    }
}

extension CodexUserInput {
    /// The image a sent message previews for this input, when it is one.
    var sentImage: TranscriptImageAttachment? {
        switch self {
        case let .localImage(url, _):
            TranscriptImageAttachment(url: url.isFileURL ? url : URL(filePath: url.path(percentEncoded: false)))
        case let .image(url, _):
            TranscriptImageAttachment(url: url)
        default:
            nil
        }
    }
}

extension CodexTurnState {
    var hasNativeUserMessage: Bool { items.contains { if case .userMessage = $0.content { true } else { false } } }
    /// The app-owned draft used by editing. It is deliberately derived only from
    /// decodable provider input envelopes; unknown historical input remains visible but cannot be
    /// silently rewritten into a different request.
    var userInputDraft: CodexComposerDraft? {
        guard let userItem = items.first(where: { item in
            if case .userMessage = item.content { return true }
            return false
        }), case let .userMessage(message) = userItem.content else { return nil }
        let inputs = message.content.compactMap(CodexUserInput.decode)
        return inputs.isEmpty || inputs.count != message.content.count ? nil : CodexComposerDraft(inputs: inputs)
    }
}

enum CodexTurnSubmission: Equatable, Sendable {
    case start
    case steer(expectedTurnID: String)
}

enum CodexComposerAction: String, Codable, Equatable, Sendable {
    case automatic
    case steer
    case queue
}

protocol CodexPendingServerRequestRepository {
    func load(for sessionID: UUID) -> [CodexPendingServerRequest]
    func save(_ requests: [CodexPendingServerRequest], for sessionID: UUID)
    func remove(for sessionID: UUID)
}

struct UserDefaultsCodexPendingServerRequestRepository: CodexPendingServerRequestRepository {
    let defaults: UserDefaults
    let keyPrefix: String

    init(
        defaults: UserDefaults = .yardlet,
        keyPrefix: String = "NativeHarnessClient.codexPendingRequests."
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    func load(for sessionID: UUID) -> [CodexPendingServerRequest] {
        guard let data = defaults.data(forKey: keyPrefix + sessionID.uuidString) else { return [] }
        return (try? JSONDecoder().decode([CodexPendingServerRequest].self, from: data)) ?? []
    }

    func save(_ requests: [CodexPendingServerRequest], for sessionID: UUID) {
        guard let data = try? JSONEncoder().encode(requests) else { return }
        defaults.set(data, forKey: keyPrefix + sessionID.uuidString)
    }

    func remove(for sessionID: UUID) {
        defaults.removeObject(forKey: keyPrefix + sessionID.uuidString)
    }
}

protocol CodexTimelineItemRepository {
    func load(for sessionID: UUID) -> [CodexPersistedTimelineItem]
    func save(_ items: [CodexPersistedTimelineItem], for sessionID: UUID)
    func remove(for sessionID: UUID)
}

/// Where the cards were kept before they had files (`FileCodexTimelineItemRepository`); the app
/// only reads it to move them.
struct UserDefaultsCodexTimelineItemRepository: CodexTimelineItemRepository {
    let defaults: UserDefaults
    let keyPrefix: String

    init(
        defaults: UserDefaults = .yardlet,
        keyPrefix: String = "NativeHarnessClient.codexTimelineItems."
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    func load(for sessionID: UUID) -> [CodexPersistedTimelineItem] {
        guard let data = defaults.data(forKey: keyPrefix + sessionID.uuidString) else { return [] }
        return (try? JSONDecoder().decode([CodexPersistedTimelineItem].self, from: data)) ?? []
    }

    func save(_ items: [CodexPersistedTimelineItem], for sessionID: UUID) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: keyPrefix + sessionID.uuidString)
    }

    func remove(for sessionID: UUID) {
        defaults.removeObject(forKey: keyPrefix + sessionID.uuidString)
    }
}

/// Each Codex task's saved cards, one JSON file per task beside the other `~/.yardlet` records.
/// Cards carry generated images, command output and tool results; one task's reached 15 MB. In
/// UserDefaults they made the app's preferences file 38–97 MB (2026-10-24), which cfprefsd wrote
/// out whole again for every card saved.
struct FileCodexTimelineItemRepository: CodexTimelineItemRepository {
    let directoryURL: URL

    static func live(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> FileCodexTimelineItemRepository {
        FileCodexTimelineItemRepository(directoryURL: homeURL
            .appending(path: YardletProduct.storageDirectoryName, directoryHint: .isDirectory)
            .appending(path: "codex-timeline-items", directoryHint: .isDirectory))
    }

    func load(for sessionID: UUID) -> [CodexPersistedTimelineItem] {
        guard let data = try? Data(contentsOf: fileURL(for: sessionID)) else { return [] }
        return (try? JSONDecoder().decode([CodexPersistedTimelineItem].self, from: data)) ?? []
    }

    func save(_ items: [CodexPersistedTimelineItem], for sessionID: UUID) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        write(data, for: sessionID)
    }

    func remove(for sessionID: UUID) {
        let url = fileURL(for: sessionID)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Moves the cards `legacy` still holds into their tasks' files, as they were saved, and
    /// removes each from `legacy` once its file is written. A file already there is newer and
    /// stays. Run at every launch; once moved, there is nothing left to move.
    func moveCards(from legacy: UserDefaultsCodexTimelineItemRepository) {
        for (key, value) in legacy.defaults.dictionaryRepresentation() where key.hasPrefix(legacy.keyPrefix) {
            guard let sessionID = UUID(uuidString: String(key.dropFirst(legacy.keyPrefix.count))),
                  let data = value as? Data else { continue }
            let url = fileURL(for: sessionID)
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
                    || write(data, for: sessionID) else { continue }
            legacy.remove(for: sessionID)
        }
    }

    @discardableResult
    private func write(_ data: Data, for sessionID: UUID) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try data.write(to: fileURL(for: sessionID), options: .atomic)
            return true
        } catch {
            // The provider remains authoritative; an unavailable card file must not break a task.
            return false
        }
    }

    private func fileURL(for sessionID: UUID) -> URL {
        directoryURL.appending(path: "\(sessionID.uuidString).json")
    }
}

protocol CodexPendingServerRequestValidating: Actor {
    /// Returns only request IDs that still have a live provider RPC context and can therefore be
    /// answered. Persisted cards are not sufficient to recreate that context after a process exit.
    func answerablePendingServerRequestIDs(
        _ requests: [CodexPendingServerRequest],
        for session: HarnessSessionHandle
    ) -> Set<String>
}

protocol CodexComposerProviding: Actor {
    func submit(
        _ draft: CodexComposerDraft,
        submission: CodexTurnSubmission,
        to session: HarnessSessionHandle
    ) async throws
    func activeTurnID(for session: HarnessSessionHandle) -> String?
}
