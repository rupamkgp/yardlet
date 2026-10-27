import Foundation
import XCTest
@testable import NativeHarnessClient

final class InlineImageInputTests: XCTestCase {
    func testOriginalImageBytesAndMIMEReachBothClaudeRoutesAfterDraftPersistence() async throws {
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 0, 255, 10])
        let url = try XCTUnwrap(InlineImageInput.url(mimeType: "image/png", base64: bytes.base64EncodedString()))
        let snapshot = TaskDraftSnapshot(text: "Edited text", attachments: [.image(url, detail: .auto)])
        let saved = try JSONDecoder().decode(TaskDraftSnapshot.self, from: JSONEncoder().encode(snapshot))
        let draft = CodexComposerDraft(inputs: [.text(saved.text)] + saved.attachments)
        let projection = HarnessUserInput.projecting(draft)
        XCTAssertTrue(projection.carriesEverything)
        XCTAssertEqual(try projection.input.encodedImages(), [.init(mimeType: "image/png", base64Data: bytes.base64EncodedString())])
        XCTAssertEqual(projection.input.promptText, "Edited text")
        XCTAssertEqual(projection.input.transcriptImages, [TranscriptImageAttachment(url: url, name: nil)])
        for routed in [false, true] {
            let transport = FakeClaudeTransport()
            let direct = ClaudeAdapter(executableURL: URL(filePath: "/tmp/claude"), transportFactory: { _ in transport })
            let adapter: any HarnessAdapter = routed
                ? YHPProviderCompatibilityAdapter(adapter: direct, manifest: HarnessProtocolCompatibilityManifest.claude()) : direct
            let handle = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp"), initialPrompt: nil))
            try await adapter.send(projection.input, to: handle)
            let frames = await transport.sentValues
            let blocks = try XCTUnwrap(frames.last?["message"]?["content"]?.arrayValue)
            XCTAssertEqual(blocks[0]["text"], .string("Edited text"))
            XCTAssertEqual(blocks[1]["source"]?["media_type"], .string("image/png"))
            XCTAssertEqual(blocks[1]["source"]?["data"], .string(bytes.base64EncodedString()))
            await adapter.close(handle)
        }
    }

    func testUntrustedOrRemoteImageEnvelopeCannotTriggerADownloadOrExposeItsPayload() throws {
        XCTAssertNil(InlineImageInput.url(mimeType: "application/pdf", base64: "AA=="))
        XCTAssertNil(InlineImageInput.url(mimeType: "image/png", base64: "not base64!"))
        XCTAssertNil(InlineImageInput.url(mimeType: "image/png", base64: ""))
        XCTAssertNil(InlineImageInput.image(from: URL(string: "data:image/png,hello")!))
        let remote = CodexUserInput.image(URL(string: "https://example.invalid/image.png")!, detail: .auto)
        XCTAssertEqual(HarnessUserInput.projecting(.init(inputs: [remote])).unsupported, [remote])
        let invalid = HarnessUserInput(text: "Text", images: [.init(url: URL(string: "data:image/png;base64,private-image-payload")!, mimeType: "image/png")])
        XCTAssertThrowsError(try invalid.encodedImages()) { error in
            XCTAssertEqual(error.localizedDescription, L10n.string("The saved image attachment is unavailable."))
            XCTAssertFalse(error.localizedDescription.contains("private-image-payload"))
        }
    }
}
