import Foundation

/// One MCP server a harness session loaded, as the harness reports it. Yardlet only shows these;
/// the harness owns the servers, their sign-ins and their settings.
struct HarnessMCPServerStatus: Equatable, Sendable, Identifiable {
    enum State: String, Equatable, Sendable {
        case connected
        /// Still starting.
        case pending
        /// The server wants the user to sign in (again).
        case needsAuthentication
        case failed
        /// Turned off in the harness's settings.
        case disabled
    }

    var name: String
    var state: State
    /// How many tools it gave the session, where the harness says.
    var toolCount: Int?

    var id: String { name }

    init(name: String, state: State, toolCount: Int? = nil) {
        self.name = name
        self.state = state
        self.toolCount = toolCount
    }

    var needsAttention: Bool { state == .failed || state == .needsAuthentication }
}

/// A harness that reports, on request and without a turn, the MCP servers its running session
/// loaded (Claude Code `mcp_status`, Codex `mcpServerStatus/list`).
protocol HarnessMCPServerStatusReading: Actor {
    func mcpServers(for session: HarnessSessionHandle) async throws -> [HarnessMCPServerStatus]
    /// What the session last reported by itself (Claude Code's `system/init`), without asking.
    /// A compatibility wrapper lays it back onto the capability states it rebuilds.
    func reportedMCPServers(for localSessionID: UUID) async -> [HarnessMCPServerStatus]?
}

/// Claude Code's MCP server reports: `system/init`'s `mcp_servers` (`name`, `status`) and the
/// `mcp_status` control request's `mcpServers` (also `tools`). Statuses are `connected`, `failed`,
/// `needs-auth`, `pending` and `disabled` (CLI 2.1.293 `McpServerStatus`).
enum ClaudeMCPServers {
    static func mcpStatusRequest(id: String) -> JSONValue {
        .object(["type": .string("control_request"), "request_id": .string(id),
                 "request": .object(["subtype": .string("mcp_status")])])
    }

    /// The servers a top-level `system/init` lists, or nil for any other frame.
    static func fromInit(_ frame: JSONValue) -> [HarnessMCPServerStatus]? {
        guard frame["type"]?.stringValue == "system", frame["subtype"]?.stringValue == "init",
              frame["parent_tool_use_id"]?.stringValue?.isEmpty != false,
              let servers = frame["mcp_servers"]?.arrayValue else { return nil }
        return decode(servers)
    }

    /// The servers an `mcp_status` answer lists, or nil when it has no list.
    static func fromStatus(_ response: JSONValue) -> [HarnessMCPServerStatus]? {
        guard let servers = response["mcpServers"]?.arrayValue else { return nil }
        return decode(servers)
    }

    private static func decode(_ rows: [JSONValue]) -> [HarnessMCPServerStatus] {
        rows.compactMap { row in
            guard let name = row["name"]?.stringValue, !name.isEmpty else { return nil }
            let state: HarnessMCPServerStatus.State = switch row["status"]?.stringValue {
            case "connected": .connected
            case "failed": .failed
            case "needs-auth": .needsAuthentication
            case "disabled": .disabled
            default: .pending
            }
            let tools = row["tools"]?.arrayValue?.count
            return HarnessMCPServerStatus(name: name, state: state, toolCount: state == .connected ? tools : nil)
        }
    }
}

/// The Codex App Server's `mcpServerStatus/list`: `data[]` with `name`, `runtimeStatus`
/// (`notStarted`, `starting`, `connected`, `authenticationRequired`, `failed`), `authStatus`
/// (`unknown`, `unsupported`, `notLoggedIn`, `bearerToken`, `oAuth`), `tools` (by name) and
/// `toolsError`, paged by `nextCursor`. Asked for a thread, it reports that thread's servers.
enum CodexMCPServers {
    static func listParams(threadID: String?, cursor: String?) -> JSONValue {
        var params: [String: JSONValue] = [
            "cursor": cursor.map(JSONValue.string) ?? .null, "limit": .integer(100),
            "detail": .string("toolsAndAuthOnly")
        ]
        if let threadID { params["threadId"] = .string(threadID) }
        return .object(params)
    }

    static func decode(_ result: JSONValue) -> (servers: [HarnessMCPServerStatus], nextCursor: String?) {
        let servers: [HarnessMCPServerStatus] = (result["data"]?.arrayValue ?? []).compactMap { row in
            guard let name = row["name"]?.stringValue, !name.isEmpty else { return nil }
            let tools = row["tools"]?.objectValue?.count ?? row["tools"]?.arrayValue?.count
            let hasError = row["toolsError"].map { $0 != .null } ?? false
            let state: HarnessMCPServerStatus.State
            switch row["runtimeStatus"]?.stringValue {
            case "connected": state = .connected
            case "starting", "notStarted": state = .pending
            case "authenticationRequired": state = .needsAuthentication
            case "failed", "cancelled": state = .failed
            default:
                // Without a running thread only the configuration and sign-in are known.
                if row["authStatus"]?.stringValue == "notLoggedIn" { state = .needsAuthentication }
                else if hasError { state = .failed }
                else { state = .connected }
            }
            return HarnessMCPServerStatus(name: name, state: state, toolCount: state == .connected ? tools : nil)
        }
        return (servers, result["nextCursor"]?.stringValue)
    }
}
