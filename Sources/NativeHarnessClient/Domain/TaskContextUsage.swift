import Foundation

/// The context a task's composer ring and session rail card last showed, kept in Yardlet's index
/// (`sessions.context_usage`, docs/NATIVE_SESSION_STORAGE.md) so they show it again right after a
/// restart, before the task attaches or its history is read. Live reports replace it; it never
/// replaces them.
struct TaskContextUsageSnapshot: Codable, Equatable, Sendable {
    /// The provider conversation the numbers belong to. A task now on another conversation (a new
    /// chat, a fork, an edit's branch) shows none of them.
    var providerSessionID: String?
    /// When Yardlet took the numbers: a saved conversation that went on after this (in another app)
    /// is read again in place of them.
    var recordedAt: Date
    /// What the harness reported through `usageUpdated`, every harness but Codex.
    var provider: HarnessProtocolUsage?
    /// Codex's thread token usage: `thread/tokenUsage/updated`, or the rollout's latest `token_count`.
    var codex: CodexThreadTokenUsage?

    var isEmpty: Bool { provider == nil && codex == nil }

    static func encoded(_ snapshot: Self) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(snapshot), as: UTF8.self)
    }

    /// Nil for a value this build cannot read (a later build's shape, a damaged row): the ring then
    /// waits for the history or a live report, as it did before the column existed.
    static func decoded(_ text: String) -> Self? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Self.self, from: Data(text.utf8))
    }
}

/// The context Claude Code's saved conversation says it fills: the usage of the main chain's last
/// response, counted as CLI 2.1.299 counts it for its status line and `/context` (`tLe` → `Y8` →
/// `rGn`): `input_tokens + cache_creation_input_tokens + cache_read_input_tokens`, output not
/// included, the last iteration's numbers when the response has them. The window is not in the
/// file; the CLI takes it from the model (`Vf`), so the caller does too.
struct ClaudeTranscriptContextUsage: Equatable, Sendable {
    /// The response's `message.model`, the API model ID (no `[1m]` suffix).
    let model: String?
    let usedTokens: UInt64
    /// The response record's `timestamp`.
    let timestamp: Date?

    /// The last response on `chain` (oldest first) that has usage, as the CLI picks it: an
    /// assistant record on the main chain whose model is not `<synthetic>` and that is not an API
    /// error or unmetered. A compaction after it leaves none, as the CLI has no response usage
    /// after a compaction until the next response. Nil when the usage counts nothing.
    static func latest(in chain: [JSONValue]) -> Self? {
        for value in chain.reversed() {
            if value["type"]?.stringValue == "system", value["subtype"]?.stringValue == "compact_boundary" {
                return nil
            }
            guard value["type"]?.stringValue == "assistant",
                  value["isSidechain"]?.boolValue != true,
                  value["isApiErrorMessage"]?.boolValue != true,
                  value["isUnmetered"]?.boolValue != true,
                  let message = value["message"], message["model"]?.stringValue != "<synthetic>",
                  let usage = message["usage"], usage.objectValue != nil else { continue }
            let counts = Self.counts(usage)
            let used = counts.input + counts.cacheCreation + counts.cacheRead
            guard used > 0 else { return nil }
            return Self(model: message["model"]?.stringValue, usedTokens: used,
                        timestamp: value["timestamp"]?.stringValue.flatMap(Self.date))
        }
        return nil
    }

    /// `Y8`: the response's own numbers, or, when it has iterations, those of the last one that is not
    /// an advisor message or a compaction and counts something (`Di`).
    private static func counts(_ usage: JSONValue) -> (input: UInt64, cacheCreation: UInt64, cacheRead: UInt64) {
        func number(_ value: JSONValue?) -> UInt64? { ClaudeEventProjector.unsigned(value) }
        let own = (input: number(usage["input_tokens"]) ?? 0,
                   cacheCreation: number(usage["cache_creation_input_tokens"]) ?? 0,
                   cacheRead: number(usage["cache_read_input_tokens"]) ?? 0)
        guard own.input + own.cacheCreation + own.cacheRead > 0,
              let iteration = usage["iterations"]?.arrayValue?.last(where: {
                  !["advisor_message", "compaction"].contains($0["type"]?.stringValue ?? "")
              }),
              ["message", "fallback_message"].contains(iteration["type"]?.stringValue ?? ""),
              let input = number(iteration["input_tokens"]),
              number(iteration["output_tokens"]) != nil,
              let cacheCreation = number(iteration["cache_creation_input_tokens"]),
              let cacheRead = number(iteration["cache_read_input_tokens"]),
              input + cacheCreation + cacheRead > 0 else { return own }
        return (input, cacheCreation, cacheRead)
    }

    private static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// The latest token usage a Codex rollout recorded: its last `event_msg` `token_count` with `info`
/// (`total_token_usage`, `last_token_usage`, `model_context_window`), which is what Codex's App
/// Server sends again as `thread/tokenUsage/updated` when the thread is resumed
/// (`token_usage_replay`). Only the file's newest part is read; nothing is written.
enum CodexRolloutTokenUsage {
    static let initialBytes = 1 << 20
    static let maximumBytes = 8 << 20

    static func latest(in file: URL) -> CodexThreadTokenUsage? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        var budget = UInt64(initialBytes)
        while true {
            let start = size > budget ? size - budget : 0
            guard (try? handle.seek(toOffset: start)) != nil,
                  let data = try? handle.read(upToCount: Int(size - start)) else { return nil }
            if let usage = latest(inLines: data, startsMidLine: start > 0) { return usage }
            guard start > 0, budget < UInt64(maximumBytes) else { return nil }
            budget = min(budget * 2, UInt64(maximumBytes))
        }
    }

    /// The last `token_count` with `info` in `data`'s lines, newest first. A first line cut by the
    /// read's start is skipped.
    static func latest(inLines data: Data, startsMidLine: Bool) -> CodexThreadTokenUsage? {
        var lines = data.split(separator: 10, omittingEmptySubsequences: true)
        if startsMidLine, !lines.isEmpty { lines.removeFirst() }
        let marker = Data(#""token_count""#.utf8)
        for line in lines.reversed() where line.range(of: marker) != nil {
            guard let value = ClaudeSubagentTranscriptReader.parseLine(Data(line)),
                  value["type"]?.stringValue == "event_msg",
                  value["payload"]?["type"]?.stringValue == "token_count",
                  let usage = tokenUsage(from: value["payload"]?["info"]) else { continue }
            return usage
        }
        return nil
    }

    /// `TokenUsageInfo` as the rollout saves it, in the App Server's shape.
    static func tokenUsage(from info: JSONValue?) -> CodexThreadTokenUsage? {
        guard let info, info.objectValue != nil,
              let total = breakdown(info["total_token_usage"]),
              let last = breakdown(info["last_token_usage"]) else { return nil }
        return CodexThreadTokenUsage(total: total, last: last,
                                     modelContextWindow: info["model_context_window"]?.integerValue)
    }

    private static func breakdown(_ value: JSONValue?) -> CodexTokenUsageBreakdown? {
        guard let input = value?["input_tokens"]?.integerValue,
              let output = value?["output_tokens"]?.integerValue,
              let total = value?["total_tokens"]?.integerValue else { return nil }
        return CodexTokenUsageBreakdown(
            inputTokens: input,
            cachedInputTokens: value?["cached_input_tokens"]?.integerValue ?? 0,
            cacheWriteInputTokens: value?["cache_write_input_tokens"]?.integerValue ?? 0,
            outputTokens: output,
            reasoningOutputTokens: value?["reasoning_output_tokens"]?.integerValue ?? 0,
            totalTokens: total)
    }
}
