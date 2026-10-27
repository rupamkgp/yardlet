import Foundation

/// The App Server's `model/list`: the models a Codex account can choose, read page by page.
enum CodexModelList {
    /// Adds one page's visible models, skipping any already listed.
    static func append(page result: JSONValue?, to options: inout [CodexModelOption]) {
        for value in result?["data"]?.arrayValue ?? [] {
            guard value["hidden"]?.boolValue != true,
                  let id = value["id"]?.stringValue,
                  let model = value["model"]?.stringValue,
                  let name = value["displayName"]?.stringValue,
                  let effort = value["defaultReasoningEffort"]?.stringValue,
                  !options.contains(where: { $0.id == id }) else { continue }
            options.append(CodexModelOption(
                id: id, model: model, displayName: name, defaultReasoningEffort: effort,
                supportedReasoningEfforts: value["supportedReasoningEfforts"]?.arrayValue?.compactMap {
                    $0["reasoningEffort"]?.stringValue
                } ?? [], isDefault: value["isDefault"]?.boolValue ?? false,
                serviceTiers: value["serviceTiers"]?.arrayValue?.compactMap { tier in
                    guard let id = tier["id"]?.stringValue, let name = tier["name"]?.stringValue else { return nil }
                    return CodexServiceTier(id: id, name: name, description: tier["description"]?.stringValue ?? "")
                } ?? (value["additionalSpeedTiers"]?.arrayValue?.compactMap { tier in
                    guard tier.stringValue == "fast" else { return nil }
                    return CodexServiceTier(id: "fast", name: L10n.string("Fast"), description: "")
                }), defaultServiceTier: value["defaultServiceTier"]?.stringValue
            ))
        }
    }

    /// Reads the list from an App Server of its own, for the new-task screen before any Codex task
    /// has listed models on this account. It starts no thread and no turn, and stops when done.
    static func read(using transport: any CodexTransport) async throws -> [CodexModelOption] {
        do {
            _ = try await transport.request(CodexProtocol.initialize(id: 1, clientVersion: "0.2"))
            var options: [CodexModelOption] = []
            var cursor: String?
            var seenCursors = Set<String>()
            var id: Int64 = 2
            repeat {
                var params: [String: JSONValue] = ["includeHidden": .bool(false), "limit": .integer(100)]
                if let cursor { params["cursor"] = .string(cursor) }
                let response = try await transport.request(CodexRPCRequest(id: id, method: "model/list", params: .object(params)))
                id += 1
                append(page: response.result, to: &options)
                cursor = response.result?["nextCursor"]?.stringValue
                if let cursor, !seenCursors.insert(cursor).inserted {
                    throw HarnessAdapterError.invalidProviderEvent("Repeated Codex model catalog cursor")
                }
            } while cursor != nil
            await transport.stop()
            return options
        } catch {
            await transport.stop()
            throw error
        }
    }
}
