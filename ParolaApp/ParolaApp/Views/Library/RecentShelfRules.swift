import CoreGraphics
import ParolaCore

/// When the Recent shelf shows, which entries it takes and how it moves between its tiles and the list.
enum RecentShelfRules {
    static let maximumTiles = 3
    static let minimumPageCount = 4
    static let minimumTileWidth: CGFloat = 200
    static let tileSpacing = DS.Spacing.regular
    static let tileHeight: CGFloat = 210

    /// Three tiles while each keeps its minimum width across the shelf, else two.
    static func tileCount(contentWidth: CGFloat) -> Int {
        let threeFit = (contentWidth - 2 * tileSpacing) / 3 >= minimumTileWidth
        return threeFit ? maximumTiles : maximumTiles - 1
    }

    /// The newest unpinned entries of a page read newest first with no filter, up to `tiles`; none on a short page or with a single tile to show.
    static func entries(
        in rows: [LibraryEntry],
        pageCount: Int,
        sortOrder: LibrarySortOrder,
        filters: LibraryListContent.ActiveFilters,
        tiles: Int
    ) -> [LibraryEntry] {
        guard sortOrder == .newest, filters.isEmpty, pageCount >= minimumPageCount else { return [] }
        let shelf = Array(rows.lazy.filter { !$0.pinned }.prefix(tiles))
        return shelf.count >= 2 ? shelf : []
    }

    enum Key {
        case left
        case right
        case up
        case down
        case `return`
        case delete
    }

    enum KeyAction: Equatable {
        case none
        case moveTo(Int)
        case leaveForList
        case open(Int)
        case delete(Int)
    }

    /// With the keyboard on a tile the arrows walk the shelf without wrapping and Down leaves for the list; Up from a list whose only selection is its first row climbs onto the first tile.
    static func action(for key: Key, cursor: Int?, tileCount: Int, firstRowIsOnlySelection: Bool) -> KeyAction {
        guard tileCount > 0 else { return .none }
        guard let cursor, cursor < tileCount else {
            return key == .up && firstRowIsOnlySelection ? .moveTo(0) : .none
        }
        switch key {
        case .left: return .moveTo(max(cursor - 1, 0))
        case .right: return .moveTo(min(cursor + 1, tileCount - 1))
        case .up: return .moveTo(cursor)
        case .down: return .leaveForList
        case .return: return .open(cursor)
        case .delete: return .delete(cursor)
        }
    }

    enum SelectionLook: Equatable {
        case none
        case active
        case inactive
    }

    /// Like a list row: the accent while the shelf holds the keyboard in the key window, grey otherwise.
    static func selectionLook(isSelected: Bool, hasFocus: Bool, windowIsKey: Bool) -> SelectionLook {
        guard isSelected else { return .none }
        return hasFocus && windowIsKey ? .active : .inactive
    }
}
