import Foundation

/// An adapter's outgoing events, kept per session: the session's sequence numbers, the newest
/// `historyLimit` events replayed to a subscriber that attaches late, and the one live
/// subscriber.
///
/// - `emit` numbers an event from 0 within its session, keeps it, and passes it to the
///   subscriber if there is one. `emit(for:projecting:)` hands the next number to code that
///   builds the envelope itself, as Codex's frame projector does; a frame that projects to no
///   event still uses its number.
/// - `subscribe` returns a stream that first replays the kept events in order and then follows
///   new ones. It replaces the previous subscriber, whose stream finishes.
/// - `finish` ends the session's stream and keeps its events and numbering, so a later
///   subscriber still replays them and new events continue the numbering.
/// - `close` finishes the session's stream and forgets its events and numbering, so a session
///   opened again under the same ID starts from 0.
///
/// An adapter actor keeps one as a stored property, so every call runs on that actor. The kept
/// events grow to a quarter past the limit and the oldest are then dropped together, as
/// `HarnessProtocolEventHistory` does, instead of copying or shifting the whole history for
/// each event.
struct HarnessEventChannel: Sendable {
    let historyLimit: Int
    private var sessions: [UUID: Session] = [:]

    init(historyLimit: Int = 500) {
        precondition(historyLimit > 0, "A late subscriber needs at least one kept event")
        self.historyLimit = historyLimit
    }

    @discardableResult
    mutating func emit(
        _ payload: HarnessEventPayload,
        for localSessionID: UUID,
        rawProviderEvent: Data? = nil
    ) -> HarnessEventEnvelope {
        let limit = historyLimit
        return sessions[localSessionID, default: Session()].emit(
            payload, localSessionID: localSessionID, rawProviderEvent: rawProviderEvent, historyLimit: limit
        )
    }

    /// Takes the session's next number, then keeps and passes on the envelope `project` builds
    /// with it. When `project` builds none, the number stays used.
    @discardableResult
    mutating func emit(
        for localSessionID: UUID,
        projecting project: (_ sequence: UInt64) -> HarnessEventEnvelope?
    ) -> HarnessEventEnvelope? {
        let sequence = sessions[localSessionID, default: Session()].takeSequence()
        guard let envelope = project(sequence) else { return nil }
        assert(
            envelope.localSessionID == localSessionID && envelope.sequence == sequence,
            "A projected event carries its session and the number it was given"
        )
        sessions[localSessionID]?.keep(envelope, historyLimit: historyLimit)
        return envelope
    }

    mutating func subscribe(to localSessionID: UUID) -> AsyncStream<HarnessEventEnvelope> {
        let stream = AsyncStream<HarnessEventEnvelope>.makeStream()
        for event in replay(for: localSessionID) {
            stream.continuation.yield(event)
        }
        sessions[localSessionID, default: Session()].replaceSubscriber(with: stream.continuation)
        return stream.stream
    }

    /// Ends the session's stream after what it has received. The kept events and the numbering
    /// stay for the next subscriber and the next event.
    mutating func finish(_ localSessionID: UUID) {
        sessions[localSessionID]?.finishSubscriber()
    }

    mutating func close(_ localSessionID: UUID) {
        sessions.removeValue(forKey: localSessionID)?.subscriber?.finish()
    }

    /// The events a subscriber attaching now receives before new ones, oldest first.
    func replay(for localSessionID: UUID) -> [HarnessEventEnvelope] {
        guard let kept = sessions[localSessionID]?.kept else { return [] }
        return kept.count > historyLimit ? Array(kept.suffix(historyLimit)) : kept
    }

    private struct Session: Sendable {
        var nextSequence: UInt64 = 0
        /// Up to a quarter more than the limit; `replay` reads only the newest `historyLimit`.
        var kept: [HarnessEventEnvelope] = []
        var subscriber: AsyncStream<HarnessEventEnvelope>.Continuation?

        mutating func takeSequence() -> UInt64 {
            defer { nextSequence += 1 }
            return nextSequence
        }

        mutating func emit(
            _ payload: HarnessEventPayload,
            localSessionID: UUID,
            rawProviderEvent: Data?,
            historyLimit: Int
        ) -> HarnessEventEnvelope {
            let envelope = HarnessEventEnvelope(
                localSessionID: localSessionID,
                sequence: takeSequence(),
                payload: payload,
                rawProviderEvent: rawProviderEvent
            )
            keep(envelope, historyLimit: historyLimit)
            return envelope
        }

        mutating func keep(_ envelope: HarnessEventEnvelope, historyLimit: Int) {
            kept.append(envelope)
            if kept.count > historyLimit + historyLimit / 4 {
                kept.removeFirst(kept.count - historyLimit)
            }
            subscriber?.yield(envelope)
        }

        mutating func replaceSubscriber(with continuation: AsyncStream<HarnessEventEnvelope>.Continuation) {
            subscriber?.finish()
            subscriber = continuation
        }

        mutating func finishSubscriber() {
            subscriber?.finish()
            subscriber = nil
        }
    }
}
