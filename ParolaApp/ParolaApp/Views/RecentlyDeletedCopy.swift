import Foundation

enum RecentlyDeletedCopy {
    static func bulkPurgeTitle(_ count: Int, bundle: Bundle = .main) -> String {
        count == 1
            ? String(localized: "Delete 1 item permanently?", bundle: bundle)
            : String(localized: "Delete \(count) items permanently?", bundle: bundle)
    }

    static func emptyTrashMessage(_ count: Int, bundle: Bundle = .main) -> String {
        count == 1
            ? String(localized: "1 item will be deleted for good.", bundle: bundle)
            : String(localized: "All \(count) items will be deleted for good.", bundle: bundle)
    }
}
