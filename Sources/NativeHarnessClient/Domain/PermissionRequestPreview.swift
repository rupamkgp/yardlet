import Foundation

/// What a tool request would do, read from the tool's own input so the person can see the change
/// before answering. Text is bounded when the preview is built, so a large write grows neither
/// the card nor the saved transcript.
enum PermissionRequestPreview: Codable, Equatable, Sendable {
    /// Replacements in one file, in the order the tool applies them.
    case edits(path: String, edits: [PermissionEditPreview], omittedEditCount: Int)
    /// A file's whole new contents.
    case write(path: String, content: PermissionPreviewText)
    /// A shell command and the provider's own description of it.
    case command(PermissionPreviewText, description: String?)

    /// Edits kept from one request; the rest are counted.
    static let editLimit = 20
}

struct PermissionEditPreview: Codable, Equatable, Sendable {
    let oldText: PermissionPreviewText
    let newText: PermissionPreviewText
    let replacesAll: Bool
}

/// The first lines of a tool's text and a count of the lines left out.
struct PermissionPreviewText: Codable, Equatable, Sendable {
    static let lineLimit = 200
    static let characterLimit = 20_000

    let text: String
    /// Lines not kept in full; a line cut short counts as left out.
    let omittedLineCount: Int

    init(text: String, omittedLineCount: Int) {
        self.text = text
        self.omittedLineCount = omittedLineCount
    }

    init(bounding source: String, lineLimit: Int = Self.lineLimit, characterLimit: Int = Self.characterLimit) {
        let window = TranscriptCodeWindow(source, lineLimit: lineLimit, characterLimit: characterLimit)
        let cutMidLine = source.dropFirst(window.text.count).first?.isNewline == false
        let kept = Self.lineCount(window.text) - (cutMidLine ? 1 : 0)
        let omitted = window.isTruncated ? Self.lineCount(source) - kept : 0
        // A window that stops only at the final newline has left nothing out.
        text = omitted > 0 ? window.text : source
        omittedLineCount = max(0, omitted)
    }

    /// Lines as an editor numbers them: a final newline ends the last line rather than starting
    /// one. Counted on bytes because a whole file can arrive here.
    static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let breaks = text.utf8.reduce(0) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
        return text.utf8.last == UInt8(ascii: "\n") ? breaks : breaks + 1
    }
}
