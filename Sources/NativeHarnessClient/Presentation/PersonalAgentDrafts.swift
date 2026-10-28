import Foundation
import Observation

@MainActor @Observable
final class PersonalAgentDraft {
    let editor = TaskComposerDraft()
    private(set) var pending: PersonalAgentSubmission?
    private(set) var storageFailed = false
    var isSending = false
    var failure: PersonalAgentFailure?
    @ObservationIgnored private let file: URL?
    @ObservationIgnored private var unreadable = false
    var needsRecovery: Bool { unreadable }

    private struct Record: Codable {
        var version = 1
        let text: String
        let pending: PersonalAgentSubmission?
    }

    init(file: URL? = nil) {
        self.file = file
        if let file {
            do {
                let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
                guard record.version == 1 else { throw CocoaError(.coderReadCorrupt) }
                editor.text = record.text
                pending = record.pending
                if pending != nil { failure = .deliveryUnknown }
            } catch CocoaError.fileReadNoSuchFile { }
            catch { unreadable = true; storageFailed = true }
        }
        editor.onChange = { [weak self] in _ = self?.save() }
    }

    /// Persist the request identity before any network write. A restarted app
    /// reconciles or retries this same request, never silently creates another.
    func prepare() -> PersonalAgentSubmission? {
        guard !isSending, !unreadable else { return nil }
        let wasPending = pending != nil
        if pending == nil {
            guard !editor.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            pending = .init(text: editor.text)
        }
        guard save() else {
            if !wasPending { pending = nil }
            return nil
        }
        return pending
    }

    func accepted(_ requestID: String) {
        guard let submission = pending, submission.requestID == requestID else { return }
        pending = nil
        failure = nil
        if editor.text == submission.text { editor.text = "" }
        _ = save()
    }

    func failed(_ failure: PersonalAgentFailure, retry: Bool) {
        self.failure = failure
        // These responses explicitly reject this attempt; its text is editable.
        // A rejection of a retry says nothing about the earlier uncertain send.
        if !retry, failure == .sendRejected || failure == .verificationRequired {
            pending = nil
        }
        _ = save()
    }

    /// Only the person's explicit confirmation abandons delivery tracking.
    /// The text stays, and nothing is sent by returning to the editor.
    @discardableResult
    func resumeEditing() -> Bool {
        guard !isSending, !unreadable else { return false }
        let previous = pending
        pending = nil
        guard save() else { pending = previous; return false }
        failure = nil
        return true
    }

    /// Keep the original unreadable bytes before saving a new editable draft.
    /// A backup failure leaves the original and the blocked state untouched.
    @discardableResult
    func recoverStorage() -> Bool {
        guard !isSending, unreadable, let file else { return false }
        do {
            let backup = file.appendingPathExtension("backup-" + UUID().uuidString)
            try FileManager.default.copyItem(at: file, to: backup)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            unreadable = false
            guard save() else { unreadable = true; return false }
            failure = nil
            return true
        } catch { storageFailed = true; return false }
    }

    @discardableResult
    func save() -> Bool {
        guard !unreadable else { storageFailed = true; return false }
        guard let file else { storageFailed = false; return true }
        do {
            let manager = FileManager.default
            let directory = file.deletingLastPathComponent()
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try JSONEncoder().encode(Record(text: editor.text, pending: pending)).write(to: file, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            storageFailed = false
            return true
        } catch { storageFailed = true; return false }
    }
}

/// One draft per complete account/home/room binding, shared between windows.
/// This directory holds only input the person wrote here, never provider history.
@MainActor
final class PersonalAgentDrafts {
    private let fileURL: ([String]) -> URL?
    private var values: [String: PersonalAgentDraft] = [:]

    init(fileURL: @escaping ([String]) -> URL? = { _ in nil }) { self.fileURL = fileURL }

    func draft(source: String, identity: PersonalAgentIdentity) -> PersonalAgentDraft {
        let binding = [source, identity.accountID, identity.userID, identity.agentID, identity.roomID]
        let key = String(decoding: try! JSONEncoder().encode(binding), as: UTF8.self)
        if let draft = values[key] { return draft }
        let draft = PersonalAgentDraft(file: fileURL(binding))
        values[key] = draft
        return draft
    }
}
