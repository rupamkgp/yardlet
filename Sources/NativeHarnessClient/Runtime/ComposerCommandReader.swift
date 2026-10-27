import Foundation

/// An explicit home-menu lookup owns a temporary provider handle, never a Yardlet task/index
/// record. No prompt, model change, permission change or resume is dispatched by this reader.
enum ComposerCommandReader {
    static func read(using adapter: any HarnessAdapter, workspaceURL: URL) async throws -> [ProviderComposerCommand] {
        guard let provider = adapter as? any ProviderCapabilityProviding else { return [] }
        try Task.checkCancellation()
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: workspaceURL, initialPrompt: nil
        ))
        do {
            try Task.checkCancellation()
            let state = try await provider.providerCapabilities(for: handle)
            try Task.checkCancellation()
            await adapter.close(handle)
            return state.composerCommands
        } catch {
            await adapter.close(handle)
            throw error
        }
    }
}
