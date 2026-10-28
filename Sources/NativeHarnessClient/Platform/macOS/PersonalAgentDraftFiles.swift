import CryptoKit
import Foundation

extension PersonalAgentDrafts {
    static let live = PersonalAgentDrafts(directory: FileManager.default.homeDirectoryForCurrentUser
        .appending(path: YardletProduct.storageDirectoryName).appending(path: "personal-agent-drafts"))

    /// The platform supplies private, bounded file names. The shared draft
    /// state only knows the complete binding and its optional storage location.
    convenience init(directory: URL) {
        self.init { binding in
            let key = SHA256.hash(data: try! JSONEncoder().encode(binding)).map { String(format: "%02x", $0) }.joined()
            return directory.appending(path: key + ".json")
        }
    }
}
