import Foundation

/// Deterministic keyboard navigation for the shared Settings section list.
/// Section IDs stay string-based so the Settings view can keep its enum private.
enum SettingsSectionNavigationProjection {
    static func focusedIndex(sectionIDs: [String], focusedID: String?) -> Int? {
        guard !sectionIDs.isEmpty else { return nil }
        if let focusedID, let index = sectionIDs.firstIndex(of: focusedID) {
            return index
        }
        return 0
    }

    static func targetSectionID(
        in sectionIDs: [String],
        focusedID: String?,
        offset: Int
    ) -> String? {
        guard let index = focusedIndex(sectionIDs: sectionIDs, focusedID: focusedID) else { return nil }
        let targetIndex = index + offset
        guard sectionIDs.indices.contains(targetIndex) else { return nil }
        return sectionIDs[targetIndex]
    }
}
