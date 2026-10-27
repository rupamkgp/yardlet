import Foundation

enum BrowserDevToolsError: LocalizedError, Equatable {
    case notSent(String)
    case protocolError(String, JSONValue)
    case timedOut(String)
    case closed

    var errorDescription: String? {
        switch self {
        case .notSent(let method): "CDP \(method) could not be sent to the browser host"
        case .protocolError(let method, let error): "CDP \(method) failed: \(error.readableText ?? "")"
        case .timedOut(let method): "CDP \(method) timed out"
        case .closed: "The browser tab closed"
        }
    }
}

/// Chrome DevTools Protocol over the browser host's `devTools` messages. It knows only CDP JSON,
/// so the same client serves any host that speaks CDP (CEF, WebView2).
@MainActor
final class BrowserDevToolsClient {
    /// Delivers a raw message to the host; returns false when it cannot.
    private let transport: (String) -> Bool
    private var nextID: Int64 = 1
    private var pending: [Int64: (method: String, continuation: CheckedContinuation<JSONValue, Error>)] = [:]
    private var eventWaiters: [(token: Int64, method: String, continuation: CheckedContinuation<JSONValue?, Never>)] = []
    /// Every event received, in order.
    private(set) var events: [(method: String, params: JSONValue)] = []
    /// Called when a call times out, and when one is answered, with its method: whether the page
    /// answers is what `BrowserTab.unresponsive` follows.
    var onTimeout: ((String) -> Void)?
    var onAnswer: ((String) -> Void)?
    /// Called with every event as it arrives (the panel's vault watch).
    private var eventObservers: [UUID: (String, JSONValue) -> Void] = [:]

    func observeEvents(_ observer: @escaping (String, JSONValue) -> Void) -> UUID {
        let token = UUID()
        eventObservers[token] = observer
        return token
    }

    func stopObservingEvents(_ token: UUID) {
        eventObservers[token] = nil
    }

    init(transport: @escaping (String) -> Bool) {
        self.transport = transport
    }

    func send(
        _ method: String, _ params: [String: JSONValue] = [:], timeout: Duration = .seconds(30)
    ) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        let data = try JSONEncoder().encode(JSONValue.object([
            "id": .integer(id), "method": .string(method), "params": .object(params)
        ]))
        let message = String(decoding: data, as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = (method, continuation)
            guard transport(message) else {
                pending.removeValue(forKey: id)?.continuation.resume(throwing: BrowserDevToolsError.notSent(method))
                return
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, let request = self.pending.removeValue(forKey: id) else { return }
                self.onTimeout?(method)
                request.continuation.resume(throwing: BrowserDevToolsError.timedOut(method))
            }
        }
    }

    /// Waits for the next event with this method name; nil after the timeout.
    func nextEvent(_ method: String, timeout: Duration = .seconds(30)) async -> JSONValue? {
        let token = nextID
        nextID += 1
        return await withCheckedContinuation { continuation in
            eventWaiters.append((token, method, continuation))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, let index = self.eventWaiters.firstIndex(where: { $0.token == token }) else { return }
                self.eventWaiters.remove(at: index).continuation.resume(returning: nil)
            }
        }
    }

    func receive(_ message: String) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(message.utf8)) else { return }
        if let id = value["id"]?.integerValue {
            guard let request = pending.removeValue(forKey: id) else { return }
            onAnswer?(request.method)
            if let error = value["error"] {
                request.continuation.resume(throwing: BrowserDevToolsError.protocolError(request.method, error))
            } else {
                request.continuation.resume(returning: value["result"] ?? .null)
            }
        } else if let method = value["method"]?.stringValue {
            let params = value["params"] ?? .null
            events.append((method, params))
            eventObservers.values.forEach { $0(method, params) }
            let matching = eventWaiters.filter { $0.method == method }
            eventWaiters.removeAll { $0.method == method }
            matching.forEach { $0.continuation.resume(returning: params) }
        }
    }

    func failPending() {
        let waiting = pending
        pending = [:]
        waiting.values.forEach { $0.continuation.resume(throwing: BrowserDevToolsError.closed) }
    }
}
