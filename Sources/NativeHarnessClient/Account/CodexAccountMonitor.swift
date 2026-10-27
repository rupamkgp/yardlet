import Foundation

/// Opt-in, account-center-scoped Codex account monitor.
///
/// The monitor owns one App Server process only while the Account Center is open. It
/// performs the same read-only account/rate-limit/usage probes as the one-shot broker,
/// then consumes the installed `account/updated`, `account/rateLimits/updated`, and
/// `account/login/completed` notifications. It never starts a thread or a turn.
actor CodexAccountMonitor {
    private let transport: any CodexTransport

    private var stream: AsyncStream<HarnessAccountSnapshot>?
    private var continuation: AsyncStream<HarnessAccountSnapshot>.Continuation?
    private var notificationTask: Task<Void, Never>?
    private var nextRequestID: Int64 = 1
    private var account: JSONValue?
    private var rateLimits: JSONValue?
    private var accountUsage: JSONValue?
    private var isStopped = false

    init(
        executableURL: URL,
        transport: (any CodexTransport)? = nil,
        environmentManager: CodexEnvironmentManager? = nil
    ) {
        self.transport = transport ?? CodexProcessTransport(
            executableURL: executableURL,
            environmentManager: environmentManager
        )
    }

    func start() async throws -> AsyncStream<HarnessAccountSnapshot> {
        if let stream { return stream }
        guard !isStopped else {
            throw HarnessAdapterError.processExited(
                code: -1,
                message: "Codex account monitor cannot restart after it has stopped"
            )
        }

        let pair = AsyncStream<HarnessAccountSnapshot>.makeStream()
        stream = pair.stream
        continuation = pair.continuation

        do {
            try await transport.start()
            let notifications = await transport.notifications()
            notificationTask = Task { [weak self] in
                for await frame in notifications {
                    guard !Task.isCancelled else { break }
                    await self?.accept(frame)
                }
            }

            _ = try await request(CodexProtocol.initialize(
                id: takeRequestID(),
                clientVersion: "0.2"
            ))
            try await refresh()
            return pair.stream
        } catch {
            await stop()
            throw error
        }
    }

    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        notificationTask?.cancel()
        notificationTask = nil
        continuation?.finish()
        continuation = nil
        stream = nil
        await transport.stop()
    }

    private func refresh() async throws {
        account = try await request(CodexRPCRequest(
            id: takeRequestID(),
            method: "account/read",
            params: .object(["refreshToken": .bool(false)])
        )).result
        rateLimits = try await request(CodexProtocol.accountRateLimits(
            id: takeRequestID()
        )).result
        accountUsage = try? await request(CodexProtocol.accountUsage(
            id: takeRequestID()
        )).result
        publish()
    }

    private func refreshAccountOnly() async {
        guard let value = try? await request(CodexRPCRequest(
            id: takeRequestID(),
            method: "account/read",
            params: .object(["refreshToken": .bool(false)])
        )).result else { return }
        account = value
        publish()
    }

    private func accept(_ frame: CodexRawFrame) async {
        guard let method = frame.message.method, let params = frame.message.params else {
            return
        }
        switch method {
        case "account/rateLimits/updated":
            rateLimits = HarnessAccountBroker.mergedCodexRateLimits(
                previous: rateLimits,
                update: params
            )
            publish()
        case "account/updated", "account/login/completed":
            await refreshAccountOnly()
        default:
            break
        }
    }

    private func publish() {
        let snapshot = HarnessAccountBroker.codexSnapshot(
            account: account,
            rateLimits: rateLimits,
            accountUsage: accountUsage
        )
        continuation?.yield(snapshot)
    }

    private func request(_ request: CodexRPCRequest) async throws -> CodexRPCIncomingMessage {
        try await transport.request(request)
    }

    private func takeRequestID() -> Int64 {
        defer { nextRequestID += 1 }
        return nextRequestID
    }
}
