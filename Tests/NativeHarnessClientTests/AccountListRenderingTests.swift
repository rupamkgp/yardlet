import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The one account list in each of its four modes, drawn in an unshown window in both appearances
/// into `.build/account-list-qa`: the new-task chip's popover, a task's account sheet, a limit
/// card's "Continue with another account" and Settings › Accounts.
@MainActor final class AccountListRenderingTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    func testEachModeDrawsTheSameRows() throws {
        let directory = try WindowlessRender.directory("account-list-qa")
        let (store, task) = try fixture()
        let runtime = RuntimeSelectionStore(discoversRuntimes: false)
        let modes: [(String, AccountListMode, NSSize)] = [
            ("new-task", .newTask(.claudeCode), NSSize(width: 642, height: 520)),
            ("switch-task", .switchTask(task), NSSize(width: 700, height: 470)),
            ("continue-after-limit", .continueAfterLimit(task), NSSize(width: 642, height: 430)),
            ("manage", .manage, NSSize(width: 629, height: 760))
        ]
        for (name, mode, size) in modes {
            let captures = try WindowlessRender.hostedInBothAppearances(name, in: directory, size: size) { appearance in
                list(mode, store: store, runtime: runtime)
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .background(ParityTheme.canvas)
                    .environment(\.colorScheme, appearance.colorScheme)
            }
            for capture in captures {
                XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 4, from: 4, background: (1, 1)), name)
            }
        }
        XCTAssertTrue(store.checkingKeys.isEmpty, "Drawing the lists checked nothing")
    }

    private func list(_ mode: AccountListMode, store: ProviderConnectionStore, runtime: RuntimeSelectionStore)
        -> some View {
        let isSheet: Bool = if case .switchTask = mode { true } else { false }
        let list = AccountList(mode: mode, store: store, runtimeSelections: runtime, onChoose: { _ in },
            onConnect: mode.session == nil ? { _ in } : nil,
            onAdd: mode.session == nil ? { _ in } : nil,
            onManage: mode == .newTask(.claudeCode) ? {} : nil,
            onDone: isSheet ? {} : nil,
            harnessUsage: AccountHarnessScope.Usage(withTasks: [.codex, .claudeCode], chosenForNewTask: .claudeCode),
            maxListHeight: mode == .manage ? nil : 360)
        return Group {
            switch mode {
            case .switchTask: list.padding(20)
            case .manage: list.padding(.horizontal, 16).padding(.top, 16)
            default: list.padding(16)
            }
        }
    }

    /// Claude accounts sharing one history (one checked twelve minutes ago, one just now, one whose
    /// last check could not finish, one signed out), one with its own history, a signed-out Claude
    /// default, and one ChatGPT account reached through Codex's default login and an OpenCode
    /// connection. A Claude task runs under the account checked twelve minutes ago.
    private func fixture() throws -> (ProviderConnectionStore, SessionRecord) {
        let root = FileManager.default.temporaryDirectory.appending(path: "account-list-render-\(UUID().uuidString)")
        let projects = root.appending(path: "shared/projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        roots.append(root)
        let store = ProviderConnectionStore()
        store.usesFixtureSnapshots = true
        let now = Date()
        func account(_ name: String, sharesHistory: Bool = true) throws -> ProviderConnection {
            let home = root.appending(path: name)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            if sharesHistory {
                try FileManager.default.createSymbolicLink(at: home.appending(path: "projects"),
                    withDestinationURL: projects)
            }
            let connection = ProviderConnection(id: name, name: "\(name)@example.test", harness: .claudeCode,
                providerID: nil, homePath: home.path, credentialSelector: nil)
            try store.save(connection)
            return connection
        }
        let developer = try account("developer")
        let personal = try account("personal")
        let jordan = try account("jordan")
        let elsewhere = try account("elsewhere", sharesHistory: false)
        let old = try account("old")
        store.publish(try claude("developer@example.test", short: 84, weekly: 94, at: now.addingTimeInterval(-720)),
            for: developer)
        store.publish(try claude("personal@example.test", short: 4, weekly: 35, at: now), for: personal)
        store.publish(try claude("jordan@example.test", short: 40, weekly: 100, at: now.addingTimeInterval(-1_800)),
            for: jordan)
        store.publish(HarnessAccountSnapshot(id: "jordan", harness: .claudeCode, providerID: nil, state: .unknown,
            accountLabel: nil, detail: "timed out", credentialOwner: "", checkedAt: now, usage: [], canLogin: true,
            canLogout: false), for: jordan)
        store.publish(try claude("elsewhere@example.test", short: 10, weekly: 20, at: now), for: elsewhere)
        store.publish(HarnessAccountSnapshot(id: "old", harness: .claudeCode, providerID: nil, state: .signedOut,
            accountLabel: nil, detail: "", credentialOwner: "", checkedAt: now, usage: [], canLogin: true,
            canLogout: false), for: old)
        let laptop = ProviderConnection(id: "opencode-laptop", name: "Laptop", harness: .openCode,
            providerID: "openai-codex", homePath: root.appending(path: "opencode").path, credentialSelector: nil)
        try store.save(laptop)
        let codexUsage = try claude("codex@example.test", short: 1, weekly: 12, at: now).usage
        let codex = HarnessAccountSnapshot(id: "codex", harness: .codex, providerID: "openai-codex", state: .signedIn,
            accountLabel: "codex@example.test", accountPlan: "ChatGPT Pro", detail: "", credentialOwner: "",
            checkedAt: now.addingTimeInterval(-180), usage: codexUsage, canLogin: false, canLogout: true)
        store.publish(HarnessAccountSnapshot(id: laptop.id, harness: .openCode, providerID: "openai-codex",
            state: .signedIn, accountLabel: "codex@example.test", accountPlan: "ChatGPT Pro", detail: "",
            credentialOwner: "", checkedAt: now.addingTimeInterval(-180), usage: codexUsage, canLogin: false,
            canLogout: true), for: laptop)
        store.publishDefaults([codex, HarnessAccountSnapshot(id: "claude-code", harness: .claudeCode, providerID: nil,
            state: .signedOut, accountLabel: nil, detail: "", credentialOwner: "", checkedAt: now, usage: [],
            canLogin: true, canLogout: false)])
        store.selection[.claudeCode] = personal.id
        let task = SessionRecord(harness: .claudeCode, workspaceURL: root,
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Yardlet 계정 전환", connection: developer)
        return (store, task)
    }

    private func claude(_ email: String, short: Double, weekly: Double, at checkedAt: Date) throws
        -> HarnessAccountSnapshot {
        let response = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"rate_limits":{"limits":[{"kind":"session","group":"session","percent":\#(short),"resets_at":"2030-01-01T05:00:00+00:00"},
          {"kind":"weekly_all","group":"weekly","percent":\#(weekly),"resets_at":"2030-01-06T00:00:00+00:00"},
          {"kind":"weekly_scoped","group":"weekly","percent":3,"scope":{"model":{"display_name":"Fable"}}}]}}
        """#.utf8))
        return HarnessAccountSnapshot(id: "claude-code", harness: .claudeCode, providerID: nil, state: .signedIn,
            accountLabel: email, accountPlan: "Claude Max plan", detail: "", credentialOwner: "",
            checkedAt: checkedAt, usage: try XCTUnwrap(ClaudeUsageProbe.usage(from: response)), canLogin: false,
            canLogout: true)
    }
}
