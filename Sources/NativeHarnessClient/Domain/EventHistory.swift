import Foundation

extension Array {
    /// Appends in place and keeps only the newest `limit` elements. Appending through a
    /// dictionary subscript (`histories[id, default: []].appendKeepingLast(...)`) mutates the
    /// stored array instead of copying it for every event.
    mutating func appendKeepingLast(_ element: Element, limit: Int) {
        append(element)
        if count > limit { removeFirst(count - limit) }
    }
}

extension HarnessProtocolEventEnvelope {
    /// A complete Codex timeline snapshot. Each one supersedes every earlier one.
    var isCodexPresentationSnapshot: Bool {
        isCodexPresentationEvent(HarnessProtocolCodexPresentationEvent.updated)
    }

    /// A Codex timeline patch against the update before it. A newer complete snapshot
    /// supersedes it too.
    var isCodexPresentationPatch: Bool {
        isCodexPresentationEvent(HarnessProtocolCodexPresentationEvent.patched)
    }

    private func isCodexPresentationEvent(_ name: String) -> Bool {
        payload.kind == .extension
            && payload.extensionEvent?.namespace == "yardlet.codex"
            && payload.extensionEvent?.name == name
    }

    /// This event's place in the sequence without the timeline a newer snapshot replaced.
    /// Consumers act only on `presentation.updated` and `presentation.patched`, so a replayed
    /// marker changes nothing.
    var supersededCodexPresentationSnapshot: HarnessProtocolEventEnvelope {
        HarnessProtocolEventEnvelope(
            id: id,
            localSessionID: localSessionID,
            timestamp: timestamp,
            sequence: sequence,
            payload: .extensionEvent(HarnessProtocolExtensionEvent(
                namespace: "yardlet.codex",
                name: HarnessProtocolCodexPresentationEvent.superseded,
                payload: .null
            ))
        )
    }
}

/// The protocol events replayed to a subscriber that attaches after a session started: the
/// newest `limit` of them, in sequence. Only the newest Codex timeline snapshot keeps its
/// timeline, with up to `presentationPatchLimit` patches after it; earlier snapshots and patches
/// keep their place as `presentation.superseded` markers. A snapshot carries the whole timeline,
/// so keeping every one grew with the square of a long task.
struct HarnessProtocolEventHistory: Sendable {
    let limit: Int
    /// Up to a quarter more than `limit` events; the oldest are dropped together once that slack
    /// fills, rather than shifting every kept event for each one appended to a full history.
    private var storage: [HarnessProtocolEventEnvelope] = []
    private var snapshotIndex: Int?
    private var patchIndices: [Int] = []

    /// Live Codex presentation patches kept after the newest snapshot.
    static let presentationPatchLimit = 64

    init(limit: Int = 500) {
        self.limit = limit
    }

    var events: [HarnessProtocolEventEnvelope] {
        storage.count > limit ? Array(storage.suffix(limit)) : storage
    }

    mutating func append(_ event: HarnessProtocolEventEnvelope) {
        if event.isCodexPresentationSnapshot {
            for index in [snapshotIndex].compactMap({ $0 }) + patchIndices {
                storage[index] = storage[index].supersededCodexPresentationSnapshot
            }
            patchIndices.removeAll()
            snapshotIndex = storage.count
        } else if event.isCodexPresentationPatch {
            patchIndices.append(storage.count)
        }
        storage.append(event)
        if patchIndices.count > Self.presentationPatchLimit {
            // A streaming task sends no new snapshot, and each patch carries the whole changed
            // card. Past the limit the replay could not start from the snapshot anyway, so the
            // snapshot goes too and a late subscriber reads a complete one instead.
            for index in [snapshotIndex].compactMap({ $0 }) + [patchIndices.removeFirst()] {
                storage[index] = storage[index].supersededCodexPresentationSnapshot
            }
            snapshotIndex = nil
        }
        guard storage.count > limit + limit / 4 else { return }
        let overflow = storage.count - limit
        storage.removeFirst(overflow)
        snapshotIndex = snapshotIndex.flatMap { $0 >= overflow ? $0 - overflow : nil }
        patchIndices = patchIndices.compactMap { $0 >= overflow ? $0 - overflow : nil }
    }
}
