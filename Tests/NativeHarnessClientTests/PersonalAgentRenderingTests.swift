import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

@MainActor
final class PersonalAgentRenderingTests: XCTestCase {
    func testTaskSectionStillShowsTheExistingWorkspace() async throws {
        let (model, task) = try makeWindowModel()
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
        let railTitles = [L10n.string("Show session rail"), L10n.string("Hide session rail")]
        let showsTaskRail = { host.accessibilityElements().contains { railTitles.contains($0.label) } }
        XCTAssertTrue(showsTaskRail(), "The shown task's header offers its session rail")
        // The row below Scheduled tasks opens personal agents; no section tabs sit above the list.
        XCTAssertTrue(Self.press(L10n.string("Personal agents"), in: host.hosting))
        let showsPersonalAgents = { host.accessibilityElements().contains { $0.label == "Dots" || $0.value == "Dots" } }
        await host.settle(until: showsPersonalAgents)
        try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: "personal-section-window.png"))
        XCTAssertFalse(showsTaskRail(), "The hidden coding task's rail and panels stay off the personal-agent screen")
        // The selected task is hidden behind personal agents: its updates stay unread until Tasks come back.
        XCTAssertFalse(model.isSessionVisible(task.id))
        await model.store.markUnread(id: task.id)
        XCTAssertTrue(Self.press(L10n.string("Back to tasks"), in: host.hosting))
        await host.settle(until: { !showsPersonalAgents() })
        XCTAssertTrue(showsTaskRail())
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

    func testNativeReaderAtNormalAndCompactWindowSizes() async throws {
        let (model, _) = try makeWindowModel()
        let agents = [
            PersonalAgent(id: .init(accountID: "example", userID: "person", agentID: "dot", roomID: "room"),
                          name: "Atlas", rootThreadID: "root", isPaused: false, isPrimary: true,
                          avatar: .init(location: "https://files.oaiusercontent.com/example-avatar", version: "v1")),
            PersonalAgent(id: .init(accountID: "example", userID: "person", agentID: "dot-2", roomID: "room-2"),
                          name: "Juniper", rootThreadID: nil, isPaused: true, isPrimary: false)
        ]
        let messages: [PersonalAgentMessage] = [
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
                  createdAt: nil, isDeleted: false,
                  attachments: [.init(fileID: "file", name: "announcement-draft.md", type: "file")])
        ]
        let directory = try WindowlessRender.directory("personal-agent-surface-qa")
        for size in [NSSize(width: 1280, height: 800), NSSize(width: 920, height: 680)] {
            for appearance in WindowlessRender.Appearance.allCases {
                let reader = RenderedPersonalAgentReader(agents: agents, messages: messages)
                let window = MainWindow(model: model) { reader }
                    .environment(\.colorScheme, appearance.colorScheme)
                    .frame(width: size.width, height: size.height)
                let host = WindowlessRender.Host(window, size: size, appearance: appearance)
                defer { host.close() }
                host.settle()
                let name = "\(Int(size.width))-\(appearance.suffix).png"
                try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: "tasks-\(name)"))
                XCTAssertTrue(Self.press(L10n.string("Personal agents"), in: host.hosting))
                await host.settle(until: { host.accessibilityElements().contains { $0.label == "announcement-draft.md" } })
                // The details and the picture arrive on their own after the conversation.
                let showsActivity = { host.accessibilityElements().contains { $0.label.contains("Prepare the launch checklist") } }
                if size.width >= 1280 { await host.settle(until: showsActivity) }
                try await waitUntil { await reader.avatarReads > 0 }
                host.settle(passes: 12)
                let capture = try host.capture()
                XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6))
                try WindowlessRender.writePNG(capture.bitmap, to: directory.appending(path: "personal-\(name)"))
                let visible = host.accessibilityElements(visibleOnly: true)
                for label in [L10n.string("Back to tasks"), "Atlas", "Juniper", L10n.string("Send message")] {
                    XCTAssertTrue(visible.contains { $0.label == label }, "\(label) is on screen at \(size)")
                }
                let showsDetails = { host.accessibilityElements(visibleOnly: true).contains { $0.label == L10n.string("Dot details") } }
                if size.width >= 1280 {
                    XCTAssertTrue(showsDetails(), "A wide window keeps the dot's details beside the conversation")
                } else {
                    // A compact window keeps the conversation's width; the details come over it on request.
                    XCTAssertFalse(showsDetails())
                    XCTAssertTrue(Self.press(L10n.string("Show dot details"), in: host.hosting))
                    await host.settle(until: showsActivity)
                    host.settle(passes: 12)
                    try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: "personal-details-\(name)"))
                    // The raised details close from their own button; the conversation and its editor stay.
                    XCTAssertTrue(Self.press(L10n.string("Hide dot details"), in: host.hosting))
                    await host.settle(until: { !showsDetails() })
                    let after = host.accessibilityElements(visibleOnly: true)
                    XCTAssertTrue(after.contains { $0.label == L10n.string("Send message") })
                    XCTAssertTrue(after.contains { $0.label == L10n.string("Show dot details") })
                }
            }
        }

        // Scrolling to the top of a long conversation reads the earlier page once, not before.
        let latest = (1...24).map { index in
            PersonalAgentMessage(id: "late-\(index)", author: index.isMultiple(of: 2) ? .agent : .person,
                                 text: "Message \(index) of the latest page.", createdAt: nil, isDeleted: false, attachments: [])
        }
        let older = [PersonalAgentMessage(id: "early", author: .agent, text: "An earlier reply.", createdAt: nil,
                                          isDeleted: false, attachments: [.init(fileID: "old", name: "older-notes.txt", type: "file")])]
        let reader = RenderedPersonalAgentReader(agents: agents, messages: latest, older: older)
        let size = NSSize(width: 1280, height: 800)
        let host = WindowlessRender.Host(MainWindow(model: model) { reader }.frame(width: size.width, height: size.height), size: size)
        defer { host.close() }
        host.settle()
        XCTAssertTrue(Self.press(L10n.string("Personal agents"), in: host.hosting))
        await host.settle(until: { host.accessibilityElements().contains { $0.label == "Juniper" } })
        host.settle(passes: 20)
        let readsBeforeScrolling = await reader.olderReads
        XCTAssertEqual(readsBeforeScrolling, 0, "The latest page at the bottom reads nothing earlier")
        let conversationScroll = try XCTUnwrap(Self.scrollViews(in: host.hosting).max {
            ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
        })
        let document = try XCTUnwrap(conversationScroll.documentView)
        // The wheel the person turns, handed to the conversation's scroll view, not posted to the system.
        for _ in 0..<40 {
            guard let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 200, wheel2: 0, wheel3: 0),
                  let event = NSEvent(cgEvent: wheel) else { break }
            conversationScroll.scrollWheel(with: event)
            host.settle(passes: 1)
        }
        await host.settle(until: { host.accessibilityElements().contains { $0.label == "older-notes.txt" } })
        host.settle(passes: 20)
        let readsAfterScrolling = await reader.olderReads
        XCTAssertEqual(readsAfterScrolling, 1, "Reaching the top reads one earlier page")
        XCTAssertTrue(host.accessibilityElements().contains { $0.label == "older-notes.txt" })
        try WindowlessRender.writePNG(host.capture().bitmap, to: directory.appending(path: "personal-earlier-page.png"))
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
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

    /// A model with one coding task that shows in a rendered window.
    private func makeWindowModel() throws -> (AppModel, SessionRecord) {
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
        return (model, task)
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

/// Fixed agents, one page of messages and their details; sending and downloading are not part of
/// these renders. The picture is drawn here, not a provider's.
private actor RenderedPersonalAgentReader: PersonalAgentClient {
    let values: [PersonalAgent]
    let page: [PersonalAgentMessage]
    let older: [PersonalAgentMessage]
    private(set) var olderReads = 0
    init(agents: [PersonalAgent], messages: [PersonalAgentMessage], older: [PersonalAgentMessage] = []) {
        values = agents; page = messages; self.older = older
    }
    func agents() async throws -> [PersonalAgent] { values }
    func messages(for agent: PersonalAgent, before: String?) async throws -> PersonalAgentPage {
        guard before != nil else { return .init(messages: page, before: older.isEmpty ? nil : page.first?.id) }
        olderReads += 1
        return .init(messages: older, before: nil)
    }
    func updates(for agent: PersonalAgent) async -> AsyncStream<PersonalAgentUpdate> { AsyncStream { $0.finish() } }
    func send(_ submission: PersonalAgentSubmission, to agent: PersonalAgent) async throws -> PersonalAgentMessage {
        throw PersonalAgentFailure.invalidResponse
    }
    func download(_ attachment: PersonalAgentAttachment, for agent: PersonalAgent) async throws -> PersonalAgentDownload {
        throw PersonalAgentFailure.invalidResponse
    }
    private(set) var avatarReads = 0
    func avatar(for agent: PersonalAgent) async throws -> Data {
        defer { avatarReads += 1 }
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSGradient(starting: .systemTeal, ending: .systemIndigo)?.draw(in: NSBezierPath(ovalIn: rect), angle: 45)
            return true
        }
        guard let tiff = image.tiffRepresentation, let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { throw PersonalAgentFailure.attachmentUnavailable }
        return data
    }
    func activity(for agent: PersonalAgent, cursor: String?) async throws -> PersonalAgentActivityPage {
        .init(items: [
            .init(id: "a1", title: "Prepare the launch checklist", status: .running, outcome: .unknown,
                  updatedAt: Date().addingTimeInterval(-300), preview: nil),
            .init(id: "a2", title: "Summarize the review notes", status: .completed, outcome: .succeeded,
                  updatedAt: Date().addingTimeInterval(-7_200), preview: "The notes are summarized.")
        ], cursor: nil)
    }
    func schedules(for agent: PersonalAgent) async throws -> [PersonalAgentSchedule] { [] }
    func computers(for agent: PersonalAgent) async throws -> [PersonalAgentComputer] {
        [.init(id: "cloud", name: "Cloud computer", isCloud: true, isAttached: true, availability: .unknown),
         .init(id: "studio", name: "Studio Mac", isCloud: false, isAttached: true, availability: .offline)]
    }
    func stop() async {}
}
