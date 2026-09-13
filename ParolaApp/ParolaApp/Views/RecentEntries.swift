import Foundation
import ParolaCore

enum RecentEntries {
    /// Rows Home draws before the layout has measured the space it has.
    static let homeFallback = 5
    static let homeMaximum = 24

    /// Selects the newest few without sorting the whole library behind them.
    static func most(of entries: [LibraryEntry], limit: Int) -> [LibraryEntry] {
        guard limit > 0 else { return [] }
        var newest: [LibraryEntry] = []
        newest.reserveCapacity(limit)
        for entry in entries {
            if newest.count == limit, entry.createdAt <= newest[limit - 1].createdAt { continue }
            let slot = newest.firstIndex { entry.createdAt > $0.createdAt } ?? newest.count
            newest.insert(entry, at: slot)
            if newest.count > limit { newest.removeLast() }
        }
        return newest
    }
}
