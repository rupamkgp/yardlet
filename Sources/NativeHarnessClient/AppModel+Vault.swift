import Foundation

extension AppModel {
    /// A task's title and harness for the vault's usage log and the words the person sees.
    func vaultTaskDescription(_ sessionID: UUID) -> (title: String, harness: String)? {
        guard let session = store.sessions.first(where: { $0.id == sessionID }) else { return nil }
        return (session.title, session.harness.displayName)
    }

    /// The vault's notice to the person (design docs/BROWSER_VAULT_DESIGN.md §6.3): Touch ID waits, or
    /// an item was asked for on another site. A click opens the task.
    func postVaultNotification(title: String, body: String, sessionID: UUID?) async {
        guard (await systemNotificationCenter.authorization()).isDeliverable else { return }
        let identifier = "yardlet-vault-\(UUID().uuidString)"
        if let sessionID {
            await systemNotificationCenter.post(SystemNotification(
                title: title, body: body, identifier: identifier, target: SystemNotificationTarget(sessionID: sessionID)))
        } else {
            await systemNotificationCenter.post(title: title, body: body, identifier: identifier)
        }
    }
}
