import Foundation

enum CodexTimelineNavigation {
    static func focusedIndex(turnIDs: [String], focusedID: String?) -> Int? {
        guard !turnIDs.isEmpty else { return nil }
        if let focusedID, let index = turnIDs.firstIndex(of: focusedID) {
            return index
        }
        return turnIDs.count - 1
    }

    static func targetID(
        turnIDs: [String],
        focusedID: String?,
        offset: Int
    ) -> String? {
        guard let index = focusedIndex(turnIDs: turnIDs, focusedID: focusedID) else { return nil }
        let targetIndex = index + offset
        guard turnIDs.indices.contains(targetIndex) else { return nil }
        return turnIDs[targetIndex]
    }
}
