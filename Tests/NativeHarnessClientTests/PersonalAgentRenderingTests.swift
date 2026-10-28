import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

@MainActor
final class PersonalAgentRenderingTests: XCTestCase {
    func testTaskSectionStillShowsTheExistingWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "yardlet-personal-section-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("PersonalAgentShell")))
        let task = SessionRecord(harness: .codex, workspaceURL: root,
            runtimeExecutableURL: URL(filePath: "/usr/bin/true"), title: "Review the release draft")
        let model = AppModel(
            store: SessionStore(sessions: [task], repository: InMemorySessionRepository(sessions: [task])),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: "queue."),
            preferences: defaults,
            codexPendingRequestRepository: UserDefaultsCodexPendingServerRequestRepository(defaults: defaults),
            codexTimelineItemRepository: UserDefaultsCodexTimelineItemRepository(defaults: defaults),
            codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: defaults, keyPrefix: "history."),
            transcriptRepository: FileTranscriptRepository(directoryURL: root.appending(path: "transcripts")),
            sessionTitleResolver: { _ in nil }, sessionTitleRetryCount: 0, restoresIndexOnLaunch: false)
        addTeardownBlock { await model.shutdown() }
        model.splits.activate(.session(task.id))
        let directory = try WindowlessRender.directory("personal-agent-qa")
        let size = NSSize(width: 1280, height: 800)
        let captures = try WindowlessRender.hostedInBothAppearances("tasks", in: directory, size: size) { appearance in
            MainWindow(model: model)
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: size.width, height: size.height)
        }
        for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
        XCTAssertEqual(model.store.selectedSessionID, task.id)
        let host = WindowlessRender.Host(MainWindow(model: model).frame(width: size.width, height: size.height), size: size)
        defer { host.close() }
        host.settle()
        XCTAssertTrue(model.isSessionVisible(task.id), "A window showing Tasks shows the selected task")
        XCTAssertTrue(Self.press(L10n.string("Personal agents"), in: host.hosting))
        let showsPersonalAgents = { host.accessibilityElements().contains { $0.label == "Dots" || $0.value == "Dots" } }
        await host.settle(until: showsPersonalAgents)
        try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: "personal-section-window.png"))
        // The selected task is hidden behind personal agents: its updates stay unread until Tasks come back.
        XCTAssertFalse(model.isSessionVisible(task.id))
        await model.store.markUnread(id: task.id)
        XCTAssertTrue(Self.press(L10n.string("Tasks"), in: host.hosting))
        await host.settle(until: { !showsPersonalAgents() })
        try await waitUntil { model.store.sessions.first { $0.id == task.id }?.hasUnreadUpdate == false }
        XCTAssertTrue(model.isSessionVisible(task.id))
        XCTAssertTrue(Self.press(L10n.string("Personal agents"), in: host.hosting))
        await host.settle(until: showsPersonalAgents)
        try await model.store.archiveSession(id: task.id)
        host.settle()
        XCTAssertTrue(showsPersonalAgents(),
                      "Removing the hidden coding task must not take over the personal-agent section.")
        model.showNewTaskFromMenuBar()
        await host.settle(until: { !showsPersonalAgents() })
        XCTAssertNil(model.store.selectedSessionID)
        XCTAssertTrue(Self.press(L10n.string("Personal agents"), in: host.hosting))
        await host.settle(until: showsPersonalAgents)
        _ = try await model.store.unarchiveSession(id: task.id)
        _ = await model.openTask(from: SystemNotificationTarget(sessionID: task.id))
        await host.settle(until: { !showsPersonalAgents() })
        XCTAssertEqual(model.store.selectedSessionID, task.id)
        host.close()
        try await waitUntil { !model.isSessionVisible(task.id) }
    }

    func testSignInAndUnavailableStatesHaveReadableActions() throws {
        let directory = try WindowlessRender.directory("personal-agent-qa")
        for (name, failure) in [("sign-in", PersonalAgentFailure.signInRequired), ("unavailable", .accessDenied)] {
            let center = PersonalAgentCenter()
            center.showUnavailable(failure)
            let size = NSSize(width: 680, height: 530)
            let captures = try WindowlessRender.hostedInBothAppearances(name, in: directory, size: size) { appearance in
                PersonalAgentsContent(center: center, onRetry: {}, onAccounts: {})
                    .environment(\.colorScheme, appearance.colorScheme)
                    .frame(width: size.width, height: size.height)
            }
            for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
        }
    }

    func testNativeReaderAtNormalAndCompactWindowSizes() throws {
        let center = PersonalAgentCenter()
        let agent = PersonalAgent(id: .init(accountID: "example", userID: "person", agentID: "dot", roomID: "room"),
            name: "Atlas", rootThreadID: nil, isPaused: false, isPrimary: true)
        center.useFixture(agents: [agent], messages: [
            .init(id: "m1", author: .person, text: "Check the launch plan and tell me what needs a decision.",
                  createdAt: nil, isDeleted: false, attachments: []),
            .init(id: "m2", author: .agent, text: """
                There are two decisions left before launch.

                - Choose the release date after the final review.
                - Confirm who will publish the announcement.

                I have kept the draft ready for your review.
                """, createdAt: nil, isDeleted: false, attachments: []),
            .init(id: "m3", author: .person, text: "Keep the announcement as a draft for now.",
                  createdAt: nil, isDeleted: false, attachments: []),
            .init(id: "m4", author: .agent, text: "The announcement is still a draft. I will wait for your decision.",
                  createdAt: nil, isDeleted: false, attachments: [])
        ])
        center.conversation?.draft.editor.text = "이 내용으로 초안을 작성해줘. 게시하기 전에는 내 확인을 받아줘."
        let directory = try WindowlessRender.directory("personal-agent-qa")
        for size in [NSSize(width: 1280, height: 800), NSSize(width: 920, height: 680)] {
            let captures = try WindowlessRender.hostedInBothAppearances("reader-\(Int(size.width))", in: directory, size: size) { appearance in
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: 50)
                        ShellSectionPicker(selection: .constant(.personalAgents))
                        PersonalAgentsSidebar(center: center,
                            accounts: [.init(harness: .codex, connection: nil, snapshot: nil, knownLabel: "dev@example.com")],
                            accountID: .constant(AccountChoice.nativeID(for: .codex)), accountMenu: .init(),
                            onAccounts: {}, onRefresh: {})
                    }
                    .frame(width: 240).background(ParityTheme.sidebar)
                    PersonalAgentsContent(center: center, onRetry: {}, onAccounts: {})
                }
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: size.width, height: size.height)
            }
            for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
        }
    }

    func testUncertainDeliveryAndAttachmentPreviewRemainReadable() throws {
        let directory = try WindowlessRender.directory("personal-agent-qa")
        let center = PersonalAgentCenter()
        let agent = PersonalAgent(id: .init(accountID: "example", userID: "person", agentID: "dot", roomID: "room"),
                                  name: "Atlas", rootThreadID: nil, isPaused: false, isPrimary: true)
        center.useFixture(agents: [agent], messages: [.init(id: "file-message", author: .agent, text: "The draft is ready.",
            createdAt: nil, isDeleted: false, attachments: [.init(fileID: "file", name: "release-draft.txt", type: "file")])])
        let draft = try XCTUnwrap(center.conversation?.draft)
        draft.editor.text = "이 초안으로 진행해줘. 게시하기 전에는 확인을 받아줘."
        _ = draft.prepare()
        draft.failed(.deliveryUnknown, retry: false)
        let size = NSSize(width: 680, height: 620)
        let host = WindowlessRender.Host(PersonalAgentsContent(center: center, onRetry: {}, onAccounts: {}), size: size)
        host.settle()
        XCTAssertTrue(host.accessibilityElements().contains { $0.label == L10n.string("Edit message") },
                      "An uncertain send needs an explicit way back to editing.")
        host.close()
        let captures = try WindowlessRender.hostedInBothAppearances("delivery-uncertain", in: directory, size: size) { appearance in
            PersonalAgentsContent(center: center, onRetry: {}, onAccounts: {})
                .environment(\.colorScheme, appearance.colorScheme).frame(width: size.width, height: size.height)
        }
        for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
        var preview: PersonalAgentPreviewFile? = try .init(download: .init(data: Data("A draft attachment for preview.".utf8), name: "../../release-draft.txt"))
        let url = try XCTUnwrap(preview?.url)
        XCTAssertEqual(url.lastPathComponent, "release-draft.txt")
        let attachmentCaptures = try WindowlessRender.hostedInBothAppearances("attachment", in: directory, size: size, passes: 80) { appearance in
            PersonalAgentAttachmentPreview(file: preview!, close: {})
                .environment(\.colorScheme, appearance.colorScheme).frame(width: size.width, height: size.height)
        }
        for capture in attachmentCaptures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }
        preview = nil
        // The hosting view may briefly retain the preview; it owns the temporary copy.
    }

    private static func press(_ label: String, in view: NSView) -> Bool {
        let attribute = "AXEnhancedUserInterface" as NSString
        _ = NSApplication.shared.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"),
                                         with: NSNumber(value: true), with: attribute)
        defer {
            _ = NSApplication.shared.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"),
                                             with: NSNumber(value: false), with: attribute)
        }
        func visit(_ node: AnyObject) -> AnyObject? {
            for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                if (child.accessibilityLabel?() ?? nil) == label { return child }
                if let found = visit(child) { return found }
            }
            return nil
        }
        return visit(view)?.accessibilityPerformPress?() ?? false
    }
}
