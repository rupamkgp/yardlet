import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Explicit opt-in: three small real model turns in a new native provider session. The
/// workbench index, drafts and preferences live in a private test directory/suite. Authentication
/// remains in the provider's existing native home; no credentials or old histories are copied.
@MainActor
final class RealProviderConversationAcceptanceTests: XCTestCase {
    func testSavedNativeReviewResultRendersWithoutAnotherModelAction() async throws {
        guard let path = ProcessInfo.processInfo.environment["NHC_CODEX_REVIEW_ACCEPTANCE_ROOT"] else { throw XCTSkip("Set the completed private QA root for read-only rendering") }
        let root = URL(filePath: path).resolvingSymlinksInPath()
        guard root.lastPathComponent.hasPrefix("Yardlet.WorkbenchAcceptance.") else { throw HarnessAdapterError.invalidProviderEvent("Private QA root required") }
        let repository = try SQLiteSessionRepository(databaseURL: root.appending(path: "index.sqlite3"))
        let saved = try await repository.loadSessions(), source = try XCTUnwrap(saved.first)
        let suite = testDefaultsSuite("Yardlet.ReviewRendering"), defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = makeModel(store: SessionStore(sessions: saved, repository: InMemorySessionRepository()), defaults: defaults, root: root)
        do {
            await model.resume(source)
            for _ in 0..<100 {
                if model.codexPresentationBySessionID[source.id]?.thread != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let state = try XCTUnwrap(model.codexPresentationBySessionID[source.id])
            XCTAssertEqual(state.thread?.turns.last?.status, .completed)
            let timeline = TaskConversationView(harness: .codex, workspaceURL: source.workspaceURL, entries: [], codexTaskState: state)
                .frame(width: 900, height: 650).environment(\.colorScheme, .light)
            _ = NSApplication.shared
            let hosting = NSHostingView(rootView: timeline), window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting; hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(200)); hosting.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)); hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let output = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: ".build/provider-acceptance/codex-review-native-result.png")
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output)
            await model.shutdown()
        } catch { await model.shutdown(); throw error }
    }

    func testClaudeActualChildResultUsesTheSavedParentScope() async throws {
        guard let binary = ProcessInfo.processInfo.environment["NHC_CLAUDE_CHILD_ACCEPTANCE_BINARY"] else {
            throw XCTSkip("Set an authenticated native Claude CLI for one parent request and one bounded child")
        }
        let auth = Process(), output = Pipe(); auth.executableURL = URL(filePath: binary)
        auth.arguments = ["auth", "status", "--json"]; auth.standardOutput = output; auth.standardError = FileHandle.nullDevice
        try auth.run(); let status = try JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any]
        auth.waitUntilExit(); guard status?["loggedIn"] as? Bool == true else { throw XCTSkip("Native Claude CLI login required; no model input sent") }
        let root = FileManager.default.temporaryDirectory.appending(path: "Yardlet.ChildAcceptance.\(UUID())").resolvingSymlinksInPath()
        let workspace = root.appending(path: "workspace"); try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let suite = testDefaultsSuite("Yardlet.ChildAcceptance"), defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let repository = try SQLiteSessionRepository(databaseURL: root.appending(path: "index.sqlite3"))
        let model = makeModel(store: SessionStore(repository: repository), defaults: defaults, root: root)
        let nonce = UUID().uuidString.prefix(8)
        do {
            let created = await model.createSession(harness: .claudeCode, workspaceURL: workspace,
                runtimeExecutableURL: URL(filePath: binary), title: "Yardlet child acceptance")
            let source = try XCTUnwrap(created, model.bootstrapError ?? "QA create failed")
            await model.send("Use exactly one general-purpose Agent/Task subagent in the foreground. Tell it to reply exactly CHILD_\(nonce) without tools, skills, files or network. After receiving that reply, respond exactly PARENT_\(nonce). Do not use other tools or delegate again.", to: source)
            let answer = try await completedClaudeAnswer(model, sessionID: source.id, count: 1, allowsFileActivities: true)
            XCTAssertTrue(answer.contains("PARENT_\(nonce)"))
            let activities = (model.transcriptBySessionID[source.id] ?? []).compactMap { entry -> HarnessActivity? in
                if case let .activity(activity, _) = entry.content, activity.subtask != nil { return activity }; return nil
            }
            let activity = try XCTUnwrap(activities.last)
            let currentSource = try current(model, id: source.id)
            let draft = model.composerDrafts.tasks.draft(for: source.id); draft.text = "Preserve the parent QA draft"
            let before = draft.snapshot
            let child = try await model.readClaudeSubtask(activityID: activity.id, from: currentSource)
            XCTAssertTrue(child.entries.contains { if case let .assistant(text, _) = $0.content { text.contains("CHILD_\(nonce)") } else { false } })
            XCTAssertEqual(draft.snapshot, before); XCTAssertEqual(try current(model, id: source.id).providerSessionID, currentSource.providerSessionID)
            let report: [String: Any] = ["workspace": workspace.path, "providerSessionID": currentSource.providerSessionID ?? "",
                "parentRequests": 1, "childAgentID": activity.subtask?.agentID ?? "", "taskID": activity.subtask?.taskID ?? "",
                "originalChildLogRead": !child.entries.isEmpty, "childMarkerVerified": true, "parentDraftPreserved": draft.snapshot == before,
                "scope": currentSource.environmentScope.rawValue, "providerHomeCopied": false]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: root.appending(path: "report.json"))
            let reports = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: ".build/provider-acceptance")
            try data.write(to: reports.appending(path: "claude-child-\(source.id).json"))
            await model.shutdown()
        } catch { await model.shutdown(); throw error }
    }

    func testCodexBranchReviewCompletesFromTheExistingQAConversation() async throws {
        guard let path = ProcessInfo.processInfo.environment["NHC_CODEX_REVIEW_ACCEPTANCE_ROOT"] else {
            throw XCTSkip("Set the prior private QA root to verify only its native branch review")
        }
        let root = URL(filePath: path).resolvingSymlinksInPath()
        guard root.lastPathComponent.hasPrefix("Yardlet.WorkbenchAcceptance.") else { throw HarnessAdapterError.invalidProviderEvent("Private QA root required") }
        let repository = try SQLiteSessionRepository(databaseURL: root.appending(path: "index.sqlite3"))
        let saved = try await repository.loadSessions(), source = try XCTUnwrap(saved.first)
        guard source.harness == .codex, source.environmentScope == .native, source.connection == nil,
              source.workspaceURL.resolvingSymlinksInPath().standardizedFileURL.path == root.appending(path: "workspace").resolvingSymlinksInPath().standardizedFileURL.path else {
            throw HarnessAdapterError.invalidProviderEvent("This review can use only the existing private QA conversation")
        }
        let suite = testDefaultsSuite("Yardlet.ReviewAcceptance"), defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = makeModel(store: SessionStore(sessions: saved, repository: repository), defaults: defaults, root: root)
        let file = source.workspaceURL.appending(path: "Add.swift"), bytes = try Data(contentsOf: file)
        do {
            await model.resume(source)
            await model.selectCodexRunLocation(.readOnly, for: source)
            let before = Set(model.codexPresentationBySessionID[source.id]?.thread?.turns.map(\.id) ?? [])
            let draft = model.composerDrafts.tasks.draft(for: source.id); draft.text = "Preserve the unsent review QA draft"
            let snapshot = draft.snapshot
            await model.startCodexReview(.baseBranch("qa-base"), in: try current(model, id: source.id))
            let review = try await completedNewCodexTurn(model, sessionID: source.id, excluding: before)
            let text = review.items.compactMap { item -> String? in
                switch item.content { case let .exitedReviewMode(value): value; case let .agentMessage(message): message.text; default: nil }
            }.joined(separator: "\n")
            XCTAssertTrue(text.contains("Add.swift")); XCTAssertTrue(text.contains("lhs")); XCTAssertTrue(text.contains("rhs"))
            for _ in 0..<100 {
                if model.codexPresentationBySessionID[source.id]?.thread?.turns.allSatisfy({ $0.status.isTerminal }) == true { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(model.codexPresentationBySessionID[source.id]?.thread?.turns.allSatisfy({ $0.status.isTerminal }) == true)
            XCTAssertEqual(draft.snapshot, snapshot); XCTAssertEqual(try Data(contentsOf: file), bytes)
            XCTAssertEqual(try current(model, id: source.id).providerSessionID, source.providerSessionID)
            let report: [String: Any] = ["workspace": source.workspaceURL.path, "providerSessionID": source.providerSessionID ?? "",
                "modelReviewActions": 1, "nativeReviewCompleted": review.status == .completed,
                "reviewFindsQAAdditionBug": text.contains("Add.swift") && text.contains("lhs") && text.contains("rhs"),
                "nativeWorkerTerminal": true, "draftPreserved": draft.snapshot == snapshot, "filePreserved": try Data(contentsOf: file) == bytes,
                "nativeIDPreserved": true, "route": "YHP via AppModel"]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: root.appending(path: "review-report.json"))
            let reports = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: ".build/provider-acceptance")
            try data.write(to: reports.appending(path: "codex-review-\(source.id).json"))
            await model.shutdown()
        } catch { await model.shutdown(); throw error }
    }

    func testCodexFastCompactAndBranchReviewThroughTheProductModel() async throws {
        guard let binary = ProcessInfo.processInfo.environment["NHC_CODEX_WORKBENCH_ACCEPTANCE_BINARY"] else {
            throw XCTSkip("Set the native CLI for a bounded Fast, compaction and branch-review acceptance")
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "Yardlet.WorkbenchAcceptance.\(UUID())").resolvingSymlinksInPath()
        let workspace = root.appending(path: "workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let file = workspace.appending(path: "Add.swift")
        try Data("func add(_ lhs: Int, _ rhs: Int) -> Int { lhs + rhs }\n".utf8).write(to: file)
        func git(_ arguments: [String]) throws {
            let process = Process(); process.executableURL = URL(filePath: "/usr/bin/git")
            process.arguments = ["-C", workspace.path, "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false",
                "-c", "user.name=Yardlet QA", "-c", "user.email=qa@example.invalid"] + arguments
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        }
        try git(["init", "--initial-branch=main"]); try git(["add", "Add.swift"])
        try git(["commit", "-m", "QA baseline"]); try git(["branch", "qa-base"])
        let buggyBytes = Data("func add(_ lhs: Int, _ rhs: Int) -> Int { lhs - rhs }\n".utf8)
        try buggyBytes.write(to: file); try git(["add", "Add.swift"]); try git(["commit", "-m", "QA review target"])
        let suite = testDefaultsSuite("Yardlet.WorkbenchAcceptance"), defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let repository = try SQLiteSessionRepository(databaseURL: root.appending(path: "index.sqlite3"))
        let model = makeModel(store: SessionStore(repository: repository), defaults: defaults, root: root)
        var actions = 0
        do {
            let created = await model.createSession(harness: .codex, workspaceURL: workspace,
                runtimeExecutableURL: URL(filePath: binary), title: "Yardlet workbench acceptance")
            let session = try XCTUnwrap(created, model.bootstrapError ?? "QA create failed")
            let providerID = try XCTUnwrap(session.providerSessionID)
            await model.selectCodexRunLocation(.readOnly, for: session)
            await model.loadCodexModels(for: session)
            let catalog = try XCTUnwrap(model.codexCapabilitiesBySessionID[session.id]?.modelCatalog)
            let option = try XCTUnwrap(catalog.models.first { $0.serviceTiers?.contains(where: { $0.id == "priority" }) == true })
            let effort = option.supportedReasoningEfforts.contains("low") ? "low" : option.defaultReasoningEffort
            await model.selectCodexModel(.init(model: option.model, reasoningEffort: effort, serviceTier: "priority"), for: session)
            let marker = "CONTEXT_" + UUID().uuidString.prefix(8)
            actions += 1; print("WORKBENCH_ACCEPTANCE phase=fast actions=\(actions)")
            await model.send("Remember this exact conversation marker: \(marker). Reply exactly ACK_\(marker). Do not use tools or skills.", to: try current(model, id: session.id))
            let fast = try await completedCodexTurn(model, sessionID: session.id, count: 1)
            XCTAssertTrue(fast.items.contains { if case let .agentMessage(message) = $0.content { message.text.contains(marker) } else { false } })
            let storedFast = CodexModelSelection.restored(from: try current(model, id: session.id).providerOptions)
            XCTAssertEqual(storedFast?.serviceTier, "priority")
            let beforeCompact = Set(model.codexPresentationBySessionID[session.id]?.thread?.turns.map(\.id) ?? [])
            model.composerDrafts.tasks.draft(for: session.id).text = "/compact"
            actions += 1; print("WORKBENCH_ACCEPTANCE phase=compact actions=\(actions)")
            await model.submitCodex(.init(inputs: [.text("/compact")]), action: .automatic, to: try current(model, id: session.id))
            let compact = try await completedNewCodexTurn(model, sessionID: session.id, excluding: beforeCompact)
            XCTAssertTrue(compact.items.contains { if case .contextCompaction = $0.content { true } else { false } })
            XCTAssertTrue(model.composerDrafts.tasks.draft(for: session.id).text.isEmpty)
            await model.selectCodexModel(.init(model: option.model, reasoningEffort: effort, serviceTier: "default"), for: try current(model, id: session.id))
            let beforeFollowup = Set(model.codexPresentationBySessionID[session.id]?.thread?.turns.map(\.id) ?? [])
            actions += 1; print("WORKBENCH_ACCEPTANCE phase=retained-context actions=\(actions)")
            await model.send("Reply only with the exact conversation marker given earlier. Do not guess or use tools or skills.", to: try current(model, id: session.id))
            let followup = try await completedNewCodexTurn(model, sessionID: session.id, excluding: beforeFollowup)
            XCTAssertTrue(followup.items.contains { if case let .agentMessage(message) = $0.content { message.text.contains(marker) } else { false } })
            let draft = model.composerDrafts.tasks.draft(for: session.id); draft.text = "Keep this unsent QA draft"
            let snapshot = draft.snapshot
            let beforeReview = Set(model.codexPresentationBySessionID[session.id]?.thread?.turns.map(\.id) ?? [])
            actions += 1; print("WORKBENCH_ACCEPTANCE phase=branch-review actions=\(actions)")
            await model.startCodexReview(.baseBranch("qa-base"), in: try current(model, id: session.id))
            let review = try await completedNewCodexTurn(model, sessionID: session.id, excluding: beforeReview, timeout: 120)
            let reviewText = review.items.compactMap { item -> String? in
                switch item.content { case let .exitedReviewMode(value): value; case let .agentMessage(message): message.text; default: nil }
            }.joined(separator: "\n")
            XCTAssertTrue(review.items.contains { if case .exitedReviewMode = $0.content { true } else { false } })
            XCTAssertTrue(reviewText.contains("Add.swift")); XCTAssertTrue(reviewText.contains("lhs")); XCTAssertTrue(reviewText.contains("rhs"))
            XCTAssertEqual(draft.snapshot, snapshot); XCTAssertEqual(try Data(contentsOf: file), buggyBytes)
            let final = try current(model, id: session.id)
            XCTAssertEqual(final.providerSessionID, providerID); XCTAssertEqual(final.environmentScope, .native); XCTAssertNil(final.connection)
            let report: [String: Any] = ["workspace": workspace.path, "localSessionID": session.id.uuidString,
                "providerSessionID": providerID, "providerActions": actions, "fastRequestedTier": "priority",
                "fastTurnCompleted": fast.status.isTerminal, "compactCompleted": compact.status.isTerminal,
                "retainedContextVerified": true, "reviewTarget": "qa-base", "reviewCompleted": review.status.isTerminal,
                "reviewFoundQAFile": reviewText.contains("Add.swift"), "draftPreserved": draft.snapshot == snapshot,
                "workspaceFileUnchanged": try Data(contentsOf: file) == buggyBytes,
                "providerHomeCopied": false, "route": "YHP via AppModel"]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            let output = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: ".build/provider-acceptance")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try data.write(to: root.appending(path: "report.json")); try data.write(to: output.appending(path: "codex-workbench-\(session.id).json"))
            await model.shutdown()
        } catch {
            await model.shutdown(); print("WORKBENCH_ACCEPTANCE actions=\(actions) root=\(root.path)"); throw error
        }
    }

    private func completedNewCodexTurn(_ model: AppModel, sessionID: UUID, excluding: Set<String>, timeout: TimeInterval = 90) async throws -> CodexTurnState {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let error = model.errorBySessionID[sessionID] { throw HarnessAdapterError.invalidProviderEvent(error) }
            if let notice = model.composerDrafts.tasks.draft(for: sessionID).notice { throw HarnessAdapterError.invalidProviderEvent(notice) }
            if let last = model.codexPresentationBySessionID[sessionID]?.thread?.turns.last,
               !excluding.contains(last.id), last.status.isTerminal,
               model.store.sessions.first(where: { $0.id == sessionID })?.status == .ready {
                guard last.status == .completed else { throw HarnessAdapterError.invalidProviderEvent("Native QA turn did not complete successfully") }
                return last
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HarnessAdapterError.invalidProviderEvent("Bounded native workbench turn timed out")
    }

    func testClaudeReviewedFileCheckpointRestoresOnlyTheQAFileThroughTheProductModel() async throws {
        guard let binary = ProcessInfo.processInfo.environment["NHC_CLAUDE_FILE_REWIND_ACCEPTANCE_BINARY"] else {
            throw XCTSkip("Set NHC_CLAUDE_FILE_REWIND_ACCEPTANCE_BINARY for one model input and reviewed restoration of one new QA file")
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "Yardlet.FileRewindAcceptance.\(UUID())").resolvingSymlinksInPath()
        let workspace = root.appending(path: "workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let file = workspace.appending(path: "checkpoint.txt")
        let nonce = UUID().uuidString.prefix(8), before = Data("BEFORE_\(nonce)\n".utf8), after = Data("AFTER_\(nonce)\n".utf8)
        try before.write(to: file)
        let suite = testDefaultsSuite("Yardlet.FileRewindAcceptance"), defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let repository = try SQLiteSessionRepository(databaseURL: root.appending(path: "index.sqlite3"))
        let model = makeModel(store: SessionStore(repository: repository), defaults: defaults, root: root)
        var submittedInputs = 0
        do {
            let created = await model.createSession(harness: .claudeCode, workspaceURL: workspace,
                runtimeExecutableURL: URL(filePath: binary), title: "Yardlet file checkpoint acceptance")
            let session = try XCTUnwrap(created, model.bootstrapError ?? "Claude QA session was not created")
            guard session.environmentScope == .native, session.connection == nil else {
                throw HarnessAdapterError.invalidProviderEvent("This check requires the authenticated default native Claude account")
            }
            await model.setProviderOption("permissionMode", value: "acceptEdits", for: session)
            let ready = try current(model, id: session.id)
            guard ready.providerOptions["permissionMode"] == "acceptEdits" else {
                throw HarnessAdapterError.invalidProviderEvent("The QA session did not accept its file-edit mode")
            }
            let providerID = try XCTUnwrap(ready.providerSessionID)
            try JSONSerialization.data(withJSONObject: ["workspace": workspace.path, "localSessionID": ready.id.uuidString,
                "providerSessionID": providerID, "file": file.path], options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appending(path: "prepared.json"))
            submittedInputs += 1
            await model.send("This is a bounded file checkpoint integration check. Use only Read and Write on \(file.path). Read that existing file, then use Write to replace its entire contents with exactly AFTER_\(nonce) followed by one newline. Do not use Bash, skills, other tools, other files or network. Reply exactly DONE after the write.", to: ready)
            _ = try await completedClaudeAnswer(model, sessionID: ready.id, count: 1, allowsFileActivities: true)
            XCTAssertEqual(try Data(contentsOf: file), after)
            let activities = (model.transcriptBySessionID[ready.id] ?? []).compactMap { entry -> HarnessActivity? in
                if case let .activity(activity, _) = entry.content { return activity }
                return nil
            }
            guard activities.contains(where: { $0.kind == "Write" }), activities.allSatisfy({ ["Read", "Write"].contains($0.kind) }) else {
                throw HarnessAdapterError.invalidProviderEvent("QA turn must use only its file Read/Write tools")
            }
            let source = try current(model, id: ready.id)
            let points = try await model.loadClaudeFilePoints(in: source)
            let point = try XCTUnwrap(points.last)
            let draft = model.composerDrafts.tasks.draft(for: source.id)
            draft.text = "Keep the unsent QA draft"
            let draftBefore = draft.snapshot
            let preview = try await model.previewClaudeFiles(pointID: point.id, in: source)
            guard preview.result.canRewind, preview.result.error == nil,
                  let files = preview.result.filesChanged, files.count == 1,
                  files.allSatisfy({ path in
                      (path.hasPrefix("/") ? URL(filePath: path) : workspace.appending(path: path))
                          .resolvingSymlinksInPath().standardizedFileURL == file.resolvingSymlinksInPath().standardizedFileURL
                  }) else {
                throw HarnessAdapterError.invalidProviderEvent("Native checkpoint preview must contain only the QA file: \(preview.result.error ?? "checkpoint unavailable")")
            }
            XCTAssertEqual(try Data(contentsOf: file), after)
            let restored = try await model.restoreClaudeFiles(preview)
            XCTAssertNil(restored.error); XCTAssertNotEqual(restored.inFlight, true)
            let restoredBytes = try Data(contentsOf: file)
            XCTAssertEqual(restoredBytes, before)
            XCTAssertEqual(draft.snapshot, draftBefore)
            let final = try current(model, id: source.id)
            XCTAssertEqual(final.providerSessionID, providerID); XCTAssertEqual(final.environmentScope, source.environmentScope)
            XCTAssertEqual(final.connection, source.connection)
            let remainingPoints = try await model.loadClaudeFilePoints(in: final)
            XCTAssertEqual(remainingPoints.map(\.id), points.map(\.id))
            let report: [String: Any] = ["workspace": workspace.path, "localSessionID": final.id.uuidString,
                "providerSessionID": providerID, "checkpointUserMessageID": point.id, "submittedModelInputs": submittedInputs,
                "reviewedFileCount": files.count, "nativeCanRewind": preview.result.canRewind,
                "originalFileBytesRestored": restoredBytes == before, "draftPreserved": draft.snapshot == draftBefore,
                "conversationIDsPreserved": remainingPoints.map(\.id) == points.map(\.id), "nativeScope": final.environmentScope == .native,
                "providerHomeCopied": false, "computerUseUsed": false, "route": "YHP via AppModel"]
            let reports = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appending(path: ".build/provider-acceptance")
            try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: root.appending(path: "report.json"))
            try data.write(to: reports.appending(path: "claude-files-\(final.id).json"))
            await model.shutdown()
        } catch {
            await model.shutdown()
            print("CLAUDE_FILE_REWIND_ACCEPTANCE submittedInputs=\(submittedInputs) root=\(root.path)")
            throw error
        }
    }

    func testClaudeAcceptanceImageIsOpaqueGreenBeforeAnyModelInput() throws {
        let data = try claudeAcceptanceImage()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        for (x, y) in [(0, 0), (16, 16), (31, 31)] {
            let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
            // Device RGB conversion depends on the host display profile; green dominance and
            // full opacity are the semantic fixture contract, not calibrated component equality.
            XCTAssertGreaterThan(color.greenComponent, 0.85)
            XCTAssertGreaterThan(color.greenComponent, color.redComponent * 2)
            XCTAssertGreaterThan(color.greenComponent, color.blueComponent * 2)
            XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.01)
        }
        let output = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: ".build/provider-acceptance/claude-image-fixture.png")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: output)
    }

    func testClaudeNativeImageEditContinuesRetainedContextThroughTheProductModel() async throws {
        guard let binary = ProcessInfo.processInfo.environment["NHC_CLAUDE_IMAGE_EDIT_ACCEPTANCE_BINARY"] else {
            throw XCTSkip("Set NHC_CLAUDE_IMAGE_EDIT_ACCEPTANCE_BINARY for three real model inputs in a new native Claude session")
        }
        let auth = Process(), output = Pipe()
        auth.executableURL = URL(filePath: binary)
        auth.arguments = ["auth", "status", "--json"]
        auth.standardOutput = output; auth.standardError = FileHandle.nullDevice
        try auth.run()
        let status = try JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any]
        auth.waitUntilExit()
        guard auth.terminationStatus == 0, status?["loggedIn"] as? Bool == true else {
            throw XCTSkip("Claude CLI login is required; no model input was sent")
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "Yardlet.ClaudeImageAcceptance.\(UUID())")
        let workspace = root.appending(path: "workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let workingFile = workspace.appending(path: "keep.txt"), workingBytes = Data("Keep these QA workspace bytes.\n".utf8)
        try workingBytes.write(to: workingFile)
        let imageBytes = try claudeAcceptanceImage()
        let image = try XCTUnwrap(InlineImageInput.url(mimeType: "image/png", base64: imageBytes.base64EncodedString()))
        let suite = testDefaultsSuite("Yardlet.ClaudeImageAcceptance"), defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let repository = try SQLiteSessionRepository(databaseURL: root.appending(path: "index.sqlite3"))
        let model = makeModel(store: SessionStore(repository: repository), defaults: defaults, root: root)
        let keep = "KEEP_" + UUID().uuidString.prefix(8), drop = "DROP_" + UUID().uuidString.prefix(8)
        let second = "Secondary marker: \(drop). Reply exactly ACK_SECONDARY. Do not use tools or skills."
        var submittedInputs = 0
        do {
            let created = await model.createSession(harness: .claudeCode, workspaceURL: workspace,
                runtimeExecutableURL: URL(filePath: binary), title: "Yardlet Claude image acceptance")
            let firstSession = try XCTUnwrap(created, model.bootstrapError ?? "Claude QA session was not created")
            guard firstSession.environmentScope == .native, firstSession.connection == nil else {
                throw HarnessAdapterError.invalidProviderEvent("This check requires the authenticated default native Claude account")
            }
            let localID = firstSession.id
            submittedInputs += 1
            await model.send("Primary marker: \(keep). Remember it only in this conversation. Reply exactly ACK_PRIMARY. Do not use tools or skills.", to: firstSession)
            _ = try await completedClaudeAnswer(model, sessionID: localID, count: 1)
            submittedInputs += 1
            await model.send(HarnessUserInput.projecting(.init(inputs: [.text(second), .image(image)])).input,
                to: try current(model, id: localID))
            _ = try await completedClaudeAnswer(model, sessionID: localID, count: 2)
            let source = try current(model, id: localID), originalID = try XCTUnwrap(source.providerSessionID)
            await model.beginClaudeEdit(second, in: source)
            let draft = model.composerDrafts.tasks.draft(for: localID)
            guard draft.editState != nil else { throw HarnessAdapterError.invalidProviderEvent(draft.notice ?? "Image edit did not open") }
            let restoredImage = try XCTUnwrap(HarnessUserInput.projecting(draft.submission).input.encodedImages().first)
            XCTAssertEqual(restoredImage.mimeType, "image/png")
            XCTAssertEqual(Data(base64Encoded: restoredImage.base64Data), imageBytes)
            let edited = "Do not use tools or skills. Return only JSON with primary (the primary marker from this conversation), secondary (the secondary marker if given, otherwise ABSENT), and color (the attached image's main color in lowercase English). Do not guess markers."
            draft.text = edited
            submittedInputs += 1
            await model.send(edited, to: source)
            let answer = try await completedClaudeAnswer(model, sessionID: localID, count: 2)
            let clean = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
            let response = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(clean.utf8)) as? [String: String])
            XCTAssertEqual(response["primary"], keep); XCTAssertEqual(response["secondary"], "ABSENT")
            XCTAssertEqual(response["color"], "green")
            let record = try current(model, id: localID)
            XCTAssertNotEqual(record.providerSessionID, originalID)
            XCTAssertEqual(record.environmentScope, source.environmentScope); XCTAssertEqual(record.connection, source.connection)
            XCTAssertEqual(record.inheritedContext?.nativeConversationOrigin?.providerSessionID, originalID)
            XCTAssertNil(draft.editState); XCTAssertEqual(try Data(contentsOf: workingFile), workingBytes)
            let report: [String: Any] = ["harness": "claude-code", "workspace": workspace.path,
                "localSessionID": localID.uuidString, "originalProviderSessionID": originalID,
                "providerSessionID": record.providerSessionID ?? "", "submittedModelInputs": submittedInputs,
                "retainedContextVerified": response["primary"] == keep, "removedContextVerified": response["secondary"] == "ABSENT",
                "imageColorVerified": response["color"] == "green", "originalImageBytesVerified": Data(base64Encoded: restoredImage.base64Data) == imageBytes,
                "workspaceFileUnchanged": try Data(contentsOf: workingFile) == workingBytes,
                "nativeScope": record.environmentScope == .native,
                "providerHomeCopied": false, "computerUseUsed": false, "route": "YHP via AppModel"]
            let reports = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appending(path: ".build/provider-acceptance")
            try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: root.appending(path: "report.json"))
            try data.write(to: reports.appending(path: "claude-image-\(localID).json"))
            await model.shutdown()
        } catch {
            await model.shutdown()
            print("CLAUDE_IMAGE_ACCEPTANCE submittedInputs=\(submittedInputs) root=\(root.path)")
            throw error
        }
    }

    func testCodexSelectedTurnForkContinuesOnlyItsNativePrefix() async throws {
        guard let binary = ProcessInfo.processInfo.environment["NHC_CODEX_CONVERSATION_ACCEPTANCE_BINARY"],
              let reportPath = ProcessInfo.processInfo.environment["NHC_CODEX_FORK_ACCEPTANCE_REPORT"] else {
            throw XCTSkip("Set the acceptance CLI and its previous test report to authorize one real fork continuation")
        }
        let report = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(filePath: reportPath))) as? [String: Any])
        let workspace = URL(filePath: try XCTUnwrap(report["workspace"] as? String))
        let sourceRoot = workspace.deletingLastPathComponent()
        guard sourceRoot.lastPathComponent.hasPrefix("Yardlet.ConversationAcceptance."),
              report["retainedContextVerified"] as? Bool == true,
              report["removedContextVerified"] as? Bool == true,
              report["nativeScope"] as? Bool == true else {
            throw HarnessAdapterError.invalidProviderEvent("Only this test's completed native parent may be forked")
        }
        let repository = try SQLiteSessionRepository(databaseURL: sourceRoot.appending(path: "index.sqlite3"))
        let saved = try await repository.loadSessions()
        let sourceID = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(report["localSessionID"] as? String)))
        let parent = try XCTUnwrap(saved.first { $0.id == sourceID })
        XCTAssertEqual(parent.providerSessionID, report["providerSessionID"] as? String)
        XCTAssertEqual(parent.runtimeExecutableURL, URL(filePath: binary).standardizedFileURL)
        let workingFile = workspace.appending(path: "keep.txt")
        let workingBytes = try Data(contentsOf: workingFile)
        let suite = testDefaultsSuite("Yardlet.ForkAcceptance")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = sourceRoot.appending(path: "fork-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = makeModel(store: SessionStore(sessions: [parent], repository: InMemorySessionRepository()),
            defaults: defaults, root: root)
        do {
            await model.resume(parent)
            _ = try await completedCodexTurn(model, sessionID: parent.id, count: 2)
            await model.loadMoreCodexTurns(for: parent)
            let original = try XCTUnwrap(model.codexPresentationBySessionID[parent.id]?.thread)
            let boundary = try XCTUnwrap(original.turns.first(where: \.hasNativeUserMessage))
            let text = try XCTUnwrap(boundary.userInputDraft?.text)
            let range = try XCTUnwrap(text.range(of: "KEEP_[A-Fa-f0-9]{8}", options: .regularExpression))
            let keep = String(text[range])
            let draft = model.composerDrafts.tasks.draft(for: parent.id)
            draft.text = "Preserve the parent's unsent draft"
            let childRecord = await model.branch(parent, at: .turn(boundary.id))
            let child = try XCTUnwrap(childRecord, model.errorBySessionID[parent.id] ?? "Native fork was not created")
            XCTAssertNotEqual(child.providerSessionID, parent.providerSessionID)
            XCTAssertEqual(child.environmentScope, parent.environmentScope)
            XCTAssertEqual(child.connection, parent.connection)
            XCTAssertEqual(child.workspaceURL, parent.workspaceURL)
            XCTAssertEqual(draft.text, "Preserve the parent's unsent draft")
            XCTAssertEqual(try Data(contentsOf: workingFile), workingBytes)
            let inherited = try XCTUnwrap(model.codexPresentationBySessionID[child.id]?.thread)
            XCTAssertEqual(inherited.turns.map(\.id), [boundary.id])
            guard inherited.turns.map(\.id) == [boundary.id] else {
                throw HarnessAdapterError.invalidProviderEvent("Native fork did not preserve the selected cut")
            }
            let prompt = "Without tools or skills, return only JSON with primary as the primary marker from this conversation and secondary as any secondary marker given, otherwise ABSENT."
            await model.send(prompt, to: child)
            let turn = try await completedCodexTurn(model, sessionID: child.id, count: 2, excluding: boundary.id)
            let answer = try XCTUnwrap(turn.items.compactMap { item -> String? in
                if case let .agentMessage(message) = item.content { return message.text }
                return nil
            }.last)
            let clean = answer.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
            let response = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(clean.utf8)) as? [String: String])
            XCTAssertEqual(response["primary"], keep)
            XCTAssertEqual(response["secondary"], "ABSENT")
            XCTAssertEqual(model.codexPresentationBySessionID[parent.id]?.thread?.turns, original.turns)
            XCTAssertEqual(model.store.sessions.first { $0.id == parent.id }?.providerSessionID, parent.providerSessionID)
            XCTAssertEqual(draft.text, "Preserve the parent's unsent draft")
            XCTAssertEqual(try Data(contentsOf: workingFile), workingBytes)
            try writeReport(root: root, session: try current(model, id: child.id), submittedTurns: 1,
                retainedContext: response["primary"] == keep, removedContext: response["secondary"] == "ABSENT")
            await model.shutdown()
        } catch { await model.shutdown(); throw error }
    }

    func testCodexNativeEditContinuesTheRetainedContextThroughTheProductModel() async throws {
        guard let binary = ProcessInfo.processInfo.environment["NHC_CODEX_CONVERSATION_ACCEPTANCE_BINARY"] else {
            throw XCTSkip("Set NHC_CODEX_CONVERSATION_ACCEPTANCE_BINARY to authorize three bounded real provider turns")
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "Yardlet.ConversationAcceptance.\(UUID())")
        let workspace = root.appending(path: "workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let workingFile = workspace.appending(path: "keep.txt")
        let originalBytes = Data("Existing workspace bytes must stay unchanged.\n".utf8)
        try originalBytes.write(to: workingFile)
        let suite = testDefaultsSuite("Yardlet.ConversationAcceptance")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let repository = try SQLiteSessionRepository(databaseURL: root.appending(path: "index.sqlite3"))
        let model = makeModel(store: SessionStore(repository: repository), defaults: defaults, root: root)
        let keep = "KEEP_" + UUID().uuidString.prefix(8)
        let drop = "DROP_" + UUID().uuidString.prefix(8)
        let first = "This is a bounded conversation integration check. Primary marker: \(keep). Remember it only in this conversation. Reply exactly ACK_PRIMARY. Do not use tools or skills."
        let second = "Secondary marker: \(drop). Remember it only in this conversation. Reply exactly ACK_SECONDARY. Do not use tools or skills."
        let edited = "Without tools or skills, return only JSON with two string fields: primary is the primary marker from this conversation; secondary is the secondary marker if one was given, otherwise ABSENT. Do not guess."
        var submittedTurns = 0
        do {
            let created = await model.createSession(harness: .codex, workspaceURL: workspace,
                runtimeExecutableURL: URL(filePath: binary), title: "Yardlet conversation acceptance")
            let session = try XCTUnwrap(created, model.bootstrapError ?? "New acceptance session failed")
            XCTAssertEqual(session.environmentScope, .native)
            let providerID = try XCTUnwrap(session.providerSessionID)
            submittedTurns += 1
            await model.send(first, to: session)
            _ = try await completedCodexTurn(model, sessionID: session.id, count: 1)
            let beforeSecond = try current(model, id: session.id)
            submittedTurns += 1
            await model.send(second, to: beforeSecond)
            let target = try await completedCodexTurn(model, sessionID: session.id, count: 2)
            let source = try current(model, id: session.id)
            model.beginCodexEdit(target, in: source)
            let draft = model.composerDrafts.tasks.draft(for: session.id)
            XCTAssertNotNil(draft.editState)
            draft.text = edited
            submittedTurns += 1
            await model.submitCodex(.init(inputs: [.text(edited)]), action: .automatic, to: source)
            let answer = try await completedCodexTurn(model, sessionID: session.id, count: 2, excluding: target.id)
            let text = try XCTUnwrap(answer.items.compactMap { item -> String? in
                if case let .agentMessage(message) = item.content { return message.text }
                return nil
            }.last)
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
            let response = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(clean.utf8)) as? [String: String])
            XCTAssertEqual(response["primary"], keep)
            XCTAssertEqual(response["secondary"], "ABSENT")
            XCTAssertFalse(text.contains(drop))
            let record = try current(model, id: session.id)
            XCTAssertEqual(record.providerSessionID, providerID)
            XCTAssertEqual(record.environmentScope, .native)
            XCTAssertNil(record.connection)
            XCTAssertNil(draft.editState)
            XCTAssertEqual(try Data(contentsOf: workingFile), originalBytes)
            XCTAssertEqual(model.store.sessions.count, 1)
            try writeReport(root: root, session: record, submittedTurns: submittedTurns,
                retainedContext: response["primary"] == keep, removedContext: response["secondary"] == "ABSENT")
            await model.shutdown()
        } catch {
            await model.shutdown()
            print("CODEX_CONVERSATION_ACCEPTANCE submittedTurns=\(submittedTurns) root=\(root.path)")
            throw error
        }
    }

    private func claudeAcceptanceImage() throws -> Data {
        // Deterministic 32x32 PNG, RGBA (0,255,0,255), generated from explicit PNG scanlines.
        // Headless AppKit bitmap generation produced a transparent raster in the real probe.
        let data = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAKklEQVR4nO3OMQ0AAAACIPuX1hg+jAIkPRMQEBAQEBAQEBAQEBAQEHgHBlfR+GotGw+YAAAAAElFTkSuQmCC"))
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: data))
        let color = try XCTUnwrap(decoded.colorAt(x: 16, y: 16)?.usingColorSpace(.deviceRGB))
        guard data.count == 99, color.greenComponent > 0.85, color.greenComponent > color.redComponent * 2,
              color.greenComponent > color.blueComponent * 2, color.alphaComponent > 0.99 else {
            throw HarnessAdapterError.invalidProviderEvent("QA image must be opaque green before any paid model input; decoded RGBA=\(color.redComponent),\(color.greenComponent),\(color.blueComponent),\(color.alphaComponent)")
        }
        return data
    }

    private func makeModel(store: SessionStore, defaults: UserDefaults, root: URL) -> AppModel {
        AppModel(store: store,
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            connections: ProviderConnectionStore(), codexEnvironmentManager: CodexEnvironmentManager(paths: .live()),
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults),
            codexPendingRequestRepository: UserDefaultsCodexPendingServerRequestRepository(defaults: defaults),
            codexTimelineItemRepository: UserDefaultsCodexTimelineItemRepository(defaults: defaults),
            codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: defaults),
            transcriptRepository: UserDefaultsTranscriptRepository(defaults: defaults),
            composerDraftRepository: FileComposerDraftRepository(directoryURL: root.appending(path: "drafts")),
            sessionTitleResolver: { _ in nil }, systemNotificationCenter: QuietAcceptanceNotificationCenter(),
            restoresIndexOnLaunch: false)
    }

    private func current(_ model: AppModel, id: UUID) throws -> SessionRecord {
        try XCTUnwrap(model.store.sessions.first { $0.id == id })
    }

    private func completedClaudeAnswer(_ model: AppModel, sessionID: UUID, count: Int,
        allowsFileActivities: Bool = false) async throws -> String {
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if let error = model.errorBySessionID[sessionID] { throw HarnessAdapterError.invalidProviderEvent(error) }
            if let notice = model.composerDrafts.tasks.draft(for: sessionID).notice {
                throw HarnessAdapterError.invalidProviderEvent(notice)
            }
            let entries = model.transcriptBySessionID[sessionID] ?? []
            if entries.contains(where: { if case .permission = $0.content { true } else { false } }) {
                throw HarnessAdapterError.invalidProviderEvent("This no-tool image check cannot grant permissions")
            }
            if model.store.sessions.first(where: { $0.id == sessionID })?.status == .ready,
               entries.filter({ if case .user = $0.content { true } else { false } }).count == count,
               let last = entries.last, case let .assistant(text, streaming) = last.content, !streaming, !text.isEmpty {
                if !allowsFileActivities {
                    XCTAssertFalse(entries.contains { if case .activity = $0.content { true } else { false } })
                }
                return text
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HarnessAdapterError.invalidProviderEvent("Bounded Claude image acceptance timed out")
    }

    private func completedCodexTurn(_ model: AppModel, sessionID: UUID, count: Int,
        excluding: String? = nil) async throws -> CodexTurnState {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if let error = model.errorBySessionID[sessionID] { throw HarnessAdapterError.invalidProviderEvent(error) }
            if let state = model.codexPresentationBySessionID[sessionID], let thread = state.thread,
               thread.turns.count == count, let last = thread.turns.last,
               last.id != excluding, last.status.isTerminal,
               model.store.sessions.first(where: { $0.id == sessionID })?.status == .ready {
                XCTAssertFalse(thread.turns.flatMap(\.items).contains { item in
                    switch item.content {
                    case .userMessage, .agentMessage, .reasoning, .hookPrompt, .plan: false
                    default: true
                    }
                })
                return last
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HarnessAdapterError.invalidProviderEvent("Bounded Codex conversation acceptance timed out")
    }

    private func writeReport(root: URL, session: SessionRecord, submittedTurns: Int,
        retainedContext: Bool, removedContext: Bool) throws {
        let report: [String: Any] = ["workspace": session.workspaceURL.path,
            "localSessionID": session.id.uuidString, "providerSessionID": session.providerSessionID ?? "",
            "providerHomeCopied": false, "nativeScope": session.environmentScope == .native,
            "submittedModelTurns": submittedTurns, "retainedContextVerified": retainedContext,
            "removedContextVerified": removedContext, "computerUseUsed": false,
            "workspaceFileUnchanged": true, "route": "YHP via AppModel"]
        let output = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: ".build/provider-acceptance")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appending(path: "report.json"))
        try data.write(to: output.appending(path: "codex-\(session.id).json"))
        print("CODEX_CONVERSATION_ACCEPTANCE retained=\(retainedContext) removed=\(removedContext) turns=\(submittedTurns)")
    }
}

@MainActor
private final class QuietAcceptanceNotificationCenter: SystemNotificationCenter {
    func authorization() async -> SystemNotificationAuthorization { .denied }
    func requestAuthorization() async -> Bool { false }
    func post(title: String, body: String, identifier: String) async {}
}
