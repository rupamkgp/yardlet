import Foundation
import XCTest
@testable import NativeHarnessClient

final class ChatWorkspacesTests: XCTestCase {
    private let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)

    func testAFolderInsideAChatRootIsAChat() {
        XCTAssertTrue(ChatWorkspaces.isChat(URL(filePath: "/Users/someone/Documents/Codex/2026-10-09/new-chat"), home: home))
        XCTAssertTrue(ChatWorkspaces.isChat(URL(filePath: "/Users/someone/Library/Application Support/Claude/scratch-workspaces/a/b/scratch-2026-10-04-7fbdb2"),
                                            home: home))
        XCTAssertTrue(ChatWorkspaces.isChat(URL(filePath: "/Users/someone/Documents/Yardlet/2026-10-12/notes/"), home: home))
    }

    func testARootItselfAndOtherFoldersAreNotChats() {
        XCTAssertFalse(ChatWorkspaces.isChat(URL(filePath: "/Users/someone/Documents/Codex"), home: home))
        XCTAssertFalse(ChatWorkspaces.isChat(URL(filePath: "/Users/someone/Documents/Codex/"), home: home))
        XCTAssertFalse(ChatWorkspaces.isChat(URL(filePath: "/Users/someone/Documents/CodexArchive/x"), home: home))
        XCTAssertFalse(ChatWorkspaces.isChat(URL(filePath: "/Users/someone/Documents/ChatGPT/13주"), home: home))
        XCTAssertFalse(ChatWorkspaces.isChat(URL(filePath: "/Users/someone/Desktop/workspace/shop"), home: home))
    }
}
