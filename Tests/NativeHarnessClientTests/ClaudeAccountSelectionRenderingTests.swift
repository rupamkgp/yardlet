import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

@MainActor
final class ClaudeAccountSelectionRenderingTests: XCTestCase {
    /// The task account sheet's rows for a Claude task: the accounts that share its history, each
    /// with its plan limits, in both appearances. Rendered without a window.
    func testClaudeTaskAccountSheetShowsSharedAccountsAndTheirLimits() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "claude-account-render-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appending(path: "shared/projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let store = ProviderConnectionStore()
        var accounts: [ProviderConnection] = []
        for (name, short, weekly) in [("personal@example.test", 2.0, 95.0), ("work@example.test", 0.0, 100.0)] {
            let home = root.appending(path: name)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: home.appending(path: "projects"), withDestinationURL: projects)
            let connection = ProviderConnection(id: name, name: name, harness: .claudeCode, providerID: nil,
                homePath: home.path, credentialSelector: nil)
            try store.save(connection)
            accounts.append(connection)
            let usage = try XCTUnwrap(ClaudeUsageProbe.usage(from: try JSONDecoder().decode(JSONValue.self, from: Data(#"""
            {"rate_limits":{"limits":[{"kind":"session","group":"session","percent":\#(short)},
              {"kind":"weekly_all","group":"weekly","percent":\#(weekly),"resets_at":"2030-01-02T00:00:00+00:00"},
              {"kind":"weekly_scoped","group":"weekly","percent":3,"scope":{"model":{"display_name":"Fable"}}}]}}
            """#.utf8))))
            store.publish(HarnessAccountSnapshot(id: name, harness: .claudeCode, providerID: nil, state: .signedIn,
                accountLabel: name, accountPlan: "Max", detail: "", credentialOwner: "Claude Code", checkedAt: Date(),
                usage: usage, canLogin: false, canLogout: true), for: connection)
        }
        let session = SessionRecord(harness: .claudeCode, workspaceURL: root, runtimeExecutableURL: URL(filePath: "/tmp/claude"),
            title: "Switch Yardlet account", connection: accounts[0])
        let directory = try WindowlessRender.directory("claude-account-qa")
        for appearance in [ColorScheme.light, .dark] {
            // The sheet lists these rows inside a ScrollView, which ImageRenderer does not draw.
            let rows = AccountListProjection.choices(.switchTask(session), store: store)
            XCTAssertEqual(rows.compactMap(\.connection), accounts, "Most limit left first")
            let view = VStack(spacing: 8) {
                ForEach(AccountListProjection.groups(rows)) { group in
                    AccountListSection(group: group, mode: .switchTask(session), store: store, onChoose: { _ in })
                }
            }.padding(20).frame(width: 660).background(ParityTheme.canvas).environment(\.colorScheme, appearance)
            let image = try WindowlessRender.image(view)
            XCTAssertGreaterThan(image.height, 200)
            try WindowlessRender.writePNG(image, to:
                directory.appending(path: appearance == .dark ? "task-account-dark.png" : "task-account-light.png"))
        }
    }
}
