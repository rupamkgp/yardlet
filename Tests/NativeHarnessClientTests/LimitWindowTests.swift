import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// B17: the three limit models (`AccountUsageMetric` from an account check, Codex's
/// `CodexAccountRateLimits` for `/status`, a session's `HarnessRateLimit` on a limit card) project
/// into one `AccountLimitWindow`, and `LimitWindowRow` draws it in each place, in that place's words.
@MainActor
final class LimitWindowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_000_000)
    private let english = CodexStatusProjection.Words(languageCode: "en", locale: Locale(identifier: "en_US"))

    // MARK: - Projection

    func testAnAccountChecksReadingKeepsItsNameShareResetAndEvidence() {
        let reset = now.addingTimeInterval(3_600)
        let metric = AccountUsageMetric(id: "claude:session:", label: L10n.format("%.0f hour limit", 5.0), usedFraction: 0.36,
            detail: L10n.format("%.0f%% remaining", 64.0), resetsAt: reset, evidence: .exactQuota)
        XCTAssertEqual(AccountLimitWindow(metric: metric), AccountLimitWindow(id: "claude:session:",
            name: L10n.format("%.0f hour limit", 5.0), remainingPercent: 64, resetsAt: reset, evidence: .exactQuota))

        // Past the cap is spent; a reading without a figure has no share; history keeps its evidence.
        let over = AccountUsageMetric(id: "over", label: "Weekly", usedFraction: 1.3, detail: "", resetsAt: nil,
                                      evidence: .exactQuota)
        XCTAssertEqual(AccountLimitWindow(metric: over).remainingPercent, 0)
        let lifetime = AccountUsageMetric(id: "account-lifetime", label: "Lifetime tokens", usedFraction: nil,
                                          detail: "12 tokens", resetsAt: nil, evidence: .accountUsage)
        XCTAssertNil(AccountLimitWindow(metric: lifetime).remainingPercent)
        XCTAssertEqual(AccountLimitWindow(metric: lifetime).evidence, .accountUsage)
    }

    func testCodexRateLimitsBecomeWindowsInTheCodexAppsWordsShortestFirst() {
        let seconds = Int64(now.timeIntervalSince1970)
        let snapshot = CodexRateLimitSnapshot(limitID: "codex", limitName: nil,
            primary: CodexRateLimitWindow(usedPercent: 12, windowDurationMinutes: 10_080, resetsAt: seconds + 259_200),
            secondary: CodexRateLimitWindow(usedPercent: 36, windowDurationMinutes: 300, resetsAt: seconds + 7_200))
        XCTAssertEqual(AccountLimitWindow.windows(snapshot, words: english), [
            AccountLimitWindow(id: "codex:secondary", name: "5h limit", remainingPercent: 64,
                               resetsAt: now.addingTimeInterval(7_200), evidence: .exactQuota),
            AccountLimitWindow(id: "codex:primary", name: "7d limit", remainingPercent: 88,
                               resetsAt: now.addingTimeInterval(259_200), evidence: .exactQuota)
        ])
        // As in the app, a window without a length is not listed; one spent past its cap has nothing left.
        let odd = CodexRateLimitSnapshot(limitID: "codex_spark", limitName: "Spark",
            primary: CodexRateLimitWindow(usedPercent: 130, windowDurationMinutes: 60, resetsAt: nil),
            secondary: CodexRateLimitWindow(usedPercent: 20, windowDurationMinutes: nil, resetsAt: nil))
        XCTAssertEqual(AccountLimitWindow.windows(odd, words: english), [
            AccountLimitWindow(id: "codex_spark:primary", name: "1h limit", remainingPercent: 0, resetsAt: nil,
                               evidence: .exactQuota)
        ])

        // `/status` rows are those windows, with the app's own label, share and reset words.
        let rows = CodexStatusProjection(threadID: nil, descendantThreadIDs: [], tokenUsage: nil,
            rateLimits: CodexAccountRateLimits(general: snapshot), selectedModel: nil, now: now, words: english).rows
        let resets = CodexStatusProjection.resetTime(now.addingTimeInterval(7_200), now: now, locale: english.locale)
        XCTAssertEqual(rows.first, .rateLimit(label: "5h limit:", remainingPercent: 64, text: "64% left",
                                              metadata: "(resets \(resets))"))
        XCTAssertEqual(rows.count, 2)
    }

    func testASessionsLimitReportBecomesWindowsInTheAccountListsWords() throws {
        let sessionReset = now.addingTimeInterval(7_200), weekReset = now.addingTimeInterval(4 * 86_400)
        let limit = HarnessRateLimit(status: .rejected, window: .session, resetsAt: sessionReset, usedFraction: 1.02,
            windows: [
                .init(window: .model, model: "Opus", usedFraction: 0.2, resetsAt: weekReset),
                .init(window: .weekly, model: nil, usedFraction: 0.41, resetsAt: weekReset),
                .init(window: .session, model: nil, usedFraction: 0.98, resetsAt: nil),
                .init(window: .overage, model: nil, usedFraction: 0.1, resetsAt: nil)
            ])
        let hours = L10n.format("%.0f hour limit", 5.0), week = L10n.format("%.0f day limit", 7.0)
        XCTAssertEqual(AccountLimitWindow.windows(reportedBy: limit), [
            AccountLimitWindow(id: "session:", name: hours, remainingPercent: 0, resetsAt: sessionReset, evidence: .exactQuota),
            AccountLimitWindow(id: "weekly:", name: week, remainingPercent: 59, resetsAt: weekReset, evidence: .exactQuota),
            AccountLimitWindow(id: "model:Opus", name: "Opus · \(week)", remainingPercent: 80, resetsAt: weekReset,
                               evidence: .exactQuota)
        ], "The limiting window's own reading wins; paid extra usage is not a window")

        // A refused window the report gave no figure for is spent; a report naming no window has none.
        let refused = HarnessRateLimit(status: .rejected, window: .model, model: "Fable", resetsAt: weekReset)
        XCTAssertEqual(AccountLimitWindow.windows(reportedBy: refused).map(\.remainingPercent), [0])
        XCTAssertEqual(AccountLimitWindow.windows(reportedBy: refused).map(\.name), ["Fable · \(week)"])
        XCTAssertEqual(AccountLimitWindow.windows(reportedBy: HarnessRateLimit(status: .rejected, message: "Limit")), [])
        XCTAssertEqual(AccountLimitWindow.windows(reportedBy: HarnessRateLimit(status: .warning, window: .weekly)), [],
                       "A warning without a figure measures nothing")
    }

    /// The same Claude windows read by a check (`get_usage`) and reported by a session on its
    /// stream are the same rows: name, share and reset.
    func testTheSameWindowsReadByACheckAndReportedByASessionMatch() throws {
        let checked = try XCTUnwrap(ClaudeUsageProbe.usage(from: try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"rate_limits":{"limits":[{"kind":"session","group":"session","percent":40,"resets_at":"2026-10-02T05:00:00+00:00"},
          {"kind":"weekly_all","group":"weekly","percent":10,"resets_at":"2026-10-06T00:00:00+00:00"},
          {"kind":"weekly_scoped","group":"weekly","percent":3,"resets_at":"2026-10-06T00:00:00+00:00",
           "scope":{"model":{"display_name":"Fable"}}}]}}
        """#.utf8))))
        let fromCheck = checked.map(AccountLimitWindow.init(metric:))
        let reported = HarnessRateLimit(status: .allowed, windows: zip(
            [HarnessRateLimit.Window.session, .weekly, .model], fromCheck).map { window, checked in
                .init(window: window, model: window == .model ? "Fable" : nil,
                      usedFraction: (100 - (checked.remainingPercent ?? 0)) / 100, resetsAt: checked.resetsAt)
            })
        let fromStream = AccountLimitWindow.windows(reportedBy: reported)
        XCTAssertEqual(fromStream.map(\.name), fromCheck.map(\.name))
        XCTAssertEqual(fromStream.map(\.resetsAt), fromCheck.map(\.resetsAt))
        for (stream, check) in zip(fromStream, fromCheck) {
            XCTAssertEqual(try XCTUnwrap(stream.remainingPercent), try XCTUnwrap(check.remainingPercent), accuracy: 0.0001)
        }
        // The account list's value words are the check's own.
        XCTAssertEqual(fromStream.map(\.accountRemainingText), checked.map(\.detail))
    }

    /// Codex's account list and `/status` read the same App Server response; they show the same
    /// share and reset under their own names.
    func testCodexsAccountListAndStatusShowTheSameShareUnderTheirOwnNames() throws {
        let seconds = Int64(now.timeIntervalSince1970)
        let response = JSONValue.object(["rateLimits": .object([
            "limitId": .string("codex"), "limitName": .null,
            "primary": .object(["usedPercent": .integer(36), "windowDurationMins": .integer(300), "resetsAt": .integer(seconds + 7_200)]),
            "secondary": .object(["usedPercent": .integer(12), "windowDurationMins": .integer(10_080),
                                  "resetsAt": .integer(seconds + 259_200)])])])
        let account = HarnessAccountBroker.codexRateLimitUsage(from: response).map(AccountLimitWindow.init(metric:))
        let status = try XCTUnwrap(CodexAccountRateLimits(response: response).general)
        let codex = AccountLimitWindow.windows(status, words: english)
        XCTAssertEqual(account.map(\.remainingPercent), codex.map(\.remainingPercent))
        XCTAssertEqual(account.map(\.resetsAt), codex.map(\.resetsAt))
        XCTAssertEqual(account.map(\.name), [L10n.format("%.0f hour limit", 5.0), L10n.format("%.0f day limit", 7.0)],
                       "Codex's one default bucket is not named")
        XCTAssertEqual(codex.map(\.name), ["5h limit", "7d limit"])
    }

    // MARK: - Rendering

    /// The one row in each place, drawn without a window into `.build/limit-row-qa/` in both
    /// appearances: Codex's `/status`, an account's limits beside it and in its popover, and a
    /// limit card.
    func testTheRowDrawsTheSameInEachPlace() throws {
        let directory = try WindowlessRender.directory("limit-row-qa")
        let seconds = Int64(Date().timeIntervalSince1970)
        let codex = CodexAccountRateLimits(response: .object(["rateLimits": .object([
            "limitId": .string("codex"),
            "primary": .object(["usedPercent": .integer(36), "windowDurationMins": .integer(300), "resetsAt": .integer(seconds + 7_200)]),
            "secondary": .object(["usedPercent": .integer(93), "windowDurationMins": .integer(10_080),
                                  "resetsAt": .integer(seconds + 259_200)])])]))
        let status = CodexStatusProjection(threadID: "019a1f2c-7d4e-7c3a-9f10-6b2d8e4c1a55", descendantThreadIDs: [],
            tokenUsage: CodexThreadTokenUsage(total: usage(64_000), last: usage(64_000), modelContextWindow: 256_000),
            rateLimits: codex, selectedModel: nil, words: english)
        let report = HarnessRateLimit(status: .rejected, window: .session, resetsAt: Date().addingTimeInterval(2 * 3_600),
            usedFraction: 1, windows: [
                .init(window: .session, model: nil, usedFraction: 1, resetsAt: Date().addingTimeInterval(2 * 3_600)),
                .init(window: .weekly, model: nil, usedFraction: 0.41, resetsAt: Date().addingTimeInterval(4 * 86_400)),
                .init(window: .model, model: "Opus", usedFraction: 0.07, resetsAt: Date().addingTimeInterval(4 * 86_400))
            ])
        let metrics = AccountLimitWindow.windows(reportedBy: report).enumerated().map { index, window in
            AccountUsageMetric(id: window.id, label: window.name, usedFraction: (100 - (window.remainingPercent ?? 0)) / 100,
                detail: index == 2 ? "\(window.accountRemainingText) · last known" : window.accountRemainingText,
                resetsAt: window.resetsAt, evidence: .exactQuota)
        }
        let connection = ProviderConnection(id: "work", name: "work@example.test", harness: .claudeCode, providerID: nil,
                                            homePath: "/tmp/limit-row-work", credentialSelector: nil)
        let choice = AccountChoice(harness: .claudeCode, connection: connection, snapshot: HarnessAccountSnapshot(
            id: "work", harness: .claudeCode, providerID: nil, state: .signedIn, accountLabel: "work@example.test",
            accountPlan: "Claude Max plan", detail: "", credentialOwner: "Claude Code", checkedAt: Date(), usage: metrics,
            canLogin: false, canLogout: true))
        let group = try XCTUnwrap(AccountGroupProjection.groups(from: [choice]).first)

        let places: [(String, NSSize, AnyView)] = [
            ("status", NSSize(width: 720, height: 170), AnyView(CodexStatusPanel(projection: status, onClose: {}).padding(12))),
            ("account-row", NSSize(width: 610, height: 92), AnyView(AccountRow(choice: choice, selected: true,
                usage: group, onSelect: {}).padding(12))),
            ("account-limits", NSSize(width: 500, height: 210), AnyView(AccountLimitsView(title: "work@example.test",
                metrics: metrics, checkedAt: Date()))),
            ("limit-card", NSSize(width: 720, height: 210), AnyView(UsageLimitCard(entryID: UUID(), limit: report,
                isLatest: false).padding(12))),
            ("limit-card-narrow", NSSize(width: 360, height: 260), AnyView(UsageLimitCard(entryID: UUID(), limit: report,
                isLatest: false).padding(12)))
        ]
        for (name, size, view) in places {
            let captures = try WindowlessRender.hostedInBothAppearances(name, in: directory, size: size) { appearance in
                view.frame(width: size.width, height: size.height, alignment: .topLeading)
                    .background(ParityTheme.canvas)
                    .environment(\.colorScheme, appearance.colorScheme)
            }
            for capture in captures {
                XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 4, from: 4, background: (1, 1)), name)
            }
        }
    }

    /// Each place's row lists the same accessible text: name, then value and reset.
    func testEachPlacesRowReadsNameThenShareThenReset() throws {
        let window = AccountLimitWindow(id: "w", name: "5 hour limit", remainingPercent: 64,
                                        resetsAt: nil, evidence: .exactQuota)
        let host = WindowlessRender.Host(LimitWindowGrid {
            LimitWindowRow(window, value: "64% remaining", reset: "Resets in 2 hr", row: 0, fontSize: 11)
        }.frame(width: 360), size: NSSize(width: 360, height: 40))
        defer { host.close() }
        host.settle(passes: 3)
        let texts = host.accessibilityElements().filter { $0.role == "AXStaticText" }.map { $0.label.isEmpty ? $0.value : $0.label }
        XCTAssertEqual(texts.first, "5 hour limit")
        XCTAssertTrue(texts.dropFirst().joined().contains("64% remaining"), "\(texts)")
        XCTAssertTrue(texts.dropFirst().joined().contains("Resets in 2 hr"), "\(texts)")
        XCTAssertFalse(texts.contains { $0.contains("█") }, "The bar is not read; the value says the same")
    }

    private func usage(_ total: Int64) -> CodexTokenUsageBreakdown {
        CodexTokenUsageBreakdown(inputTokens: total, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0,
                                 reasoningOutputTokens: 0, totalTokens: total)
    }
}
