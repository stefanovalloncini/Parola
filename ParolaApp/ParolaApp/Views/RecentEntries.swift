import Foundation
import ParolaCore

enum RecentEntries {
    static let homeLimit = 5

    static func most(of entries: [LibraryEntry], limit: Int = homeLimit) -> [LibraryEntry] {
        Array(entries.sorted { $0.createdAt > $1.createdAt }.prefix(max(0, limit)))
    }
}
