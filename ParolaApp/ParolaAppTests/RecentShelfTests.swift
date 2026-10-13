import Foundation
import Testing
import ParolaCore
@testable import Parola

@Suite("Recent shelf rules")
struct RecentShelfTests {
    private func entry(_ index: Int, pinned: Bool = false) -> LibraryEntry {
        let manifest = ParolaDocument.Manifest(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(index) * 3_600),
            originalAudioName: "take-\(index).m4a",
            title: "Take \(index)",
            modelName: "stub",
            language: "en",
            pinned: pinned,
            durationSeconds: 60
        )
        return LibraryEntry(id: "e\(index)", bundleURL: URL(fileURLWithPath: "/tmp/RecentShelfTests/e\(index).parola"), manifest: manifest)
    }

    private func shelf(
        _ rows: [LibraryEntry],
        pageCount: Int? = nil,
        sort: LibrarySortOrder = .newest,
        filters: LibraryListContent.ActiveFilters = .init(),
        tiles: Int = 3
    ) -> [String] {
        RecentShelfRules.entries(
            in: rows, pageCount: pageCount ?? rows.count, sortOrder: sort, filters: filters, tiles: tiles
        ).map(\.id)
    }

    @Test("three newest entries of a page of four or more")
    func takesTheNewestThree() {
        let rows = (0..<6).map { entry($0) }
        #expect(shelf(rows) == ["e0", "e1", "e2"])
        #expect(shelf(Array(rows.prefix(4))) == ["e0", "e1", "e2"])
    }

    @Test("a page of three or fewer has no shelf")
    func shortPageHasNone() {
        #expect(shelf((0..<3).map { entry($0) }).isEmpty)
        #expect(shelf([]).isEmpty)
    }

    @Test("pinned entries stay in the list and the shelf takes the next unpinned ones")
    func pinnedAreSkipped() {
        let rows = [entry(0, pinned: true), entry(1, pinned: true), entry(2), entry(3), entry(4), entry(5)]
        #expect(shelf(rows) == ["e2", "e3", "e4"])
    }

    @Test("fewer than two unpinned entries leave no shelf")
    func needsTwoTiles() {
        let rows = [entry(0, pinned: true), entry(1, pinned: true), entry(2, pinned: true), entry(3)]
        #expect(shelf(rows).isEmpty)
        let two = [entry(0, pinned: true), entry(1, pinned: true), entry(2), entry(3)]
        #expect(shelf(two) == ["e2", "e3"])
    }

    @Test("only Newest First shows it")
    func onlyNewestFirst() {
        let rows = (0..<6).map { entry($0) }
        for order in LibrarySortOrder.allCases where order != .newest {
            #expect(shelf(rows, sort: order).isEmpty, "\(order)")
        }
    }

    @Test("any filter hides it, a person's page included")
    func filtersHideIt() {
        let rows = (0..<6).map { entry($0) }
        #expect(shelf(rows, filters: .init(label: "Work")).isEmpty)
        #expect(shelf(rows, filters: .init(language: "en")).isEmpty)
        #expect(shelf(rows, filters: .init(dateRange: .month)).isEmpty)
        #expect(shelf(rows, filters: .init(person: UUID())).isEmpty)
    }

    @Test("the page's own count decides, not what a filter leaves")
    func pageCountDecides() {
        let rows = (0..<3).map { entry($0) }
        #expect(shelf(rows, pageCount: 9).count == 3)
        #expect(shelf(rows, pageCount: 3).isEmpty)
    }

    @Test("two tiles take the two newest")
    func twoTiles() {
        let rows = (0..<6).map { entry($0) }
        #expect(shelf(rows, tiles: 2) == ["e0", "e1"])
    }

    @Test("a shelf of a large library costs the three it takes, and leaves the rest alone")
    func largeLibrary() {
        let rows = (0..<20_000).map { entry($0) }
        #expect(shelf(rows) == ["e0", "e1", "e2"])
    }

    @Test("three tiles while each keeps 200 pt, else two")
    func tileCountFollowsWidth() {
        #expect(RecentShelfRules.tileCount(contentWidth: 772) == 3)
        #expect(RecentShelfRules.tileCount(contentWidth: 624) == 3)
        #expect(RecentShelfRules.tileCount(contentWidth: 623) == 2)
        #expect(RecentShelfRules.tileCount(contentWidth: 400) == 2)
    }

    @Test("the narrowest window keeps three tiles, and a column-wide pane gets 772 points of content")
    func widthAtTheExtremes() {
        let narrowestPane: CGFloat = 920 - 240
        #expect(RecentShelfRules.tileCount(contentWidth: EntryRowMetrics.shelfWidth(paneWidth: narrowestPane)) == 3)
        #expect(EntryRowMetrics.shelfWidth(paneWidth: 1_500) == 772)
        #expect(RecentShelfRules.tileCount(contentWidth: EntryRowMetrics.shelfWidth(paneWidth: 640)) == 2)
    }

    private func act(_ key: RecentShelfRules.Key, cursor: Int?, tiles: Int = 3, firstRow: Bool = false) -> RecentShelfRules.KeyAction {
        RecentShelfRules.action(for: key, cursor: cursor, tileCount: tiles, firstRowIsOnlySelection: firstRow)
    }

    @Test("arrows walk the tiles without wrapping")
    func arrowsWalkTheShelf() {
        #expect(act(.left, cursor: 1) == .moveTo(0))
        #expect(act(.right, cursor: 1) == .moveTo(2))
        #expect(act(.left, cursor: 0) == .moveTo(0))
        #expect(act(.right, cursor: 2) == .moveTo(2))
        #expect(act(.up, cursor: 1) == .moveTo(1))
    }

    @Test("Down leaves the shelf for the list, and Up from the first row climbs back")
    func shelfAndListHandOver() {
        #expect(act(.down, cursor: 1) == .leaveForList)
        #expect(act(.up, cursor: nil, firstRow: true) == .moveTo(0))
        #expect(act(.up, cursor: nil, firstRow: false) == .none)
        #expect(act(.down, cursor: nil, firstRow: true) == .none)
    }

    @Test("Return opens the tile and Delete removes it")
    func returnAndDelete() {
        #expect(act(.return, cursor: 2) == .open(2))
        #expect(act(.delete, cursor: 0) == .delete(0))
        #expect(act(.return, cursor: nil) == .none)
    }

    @Test("a shelf that is gone or a stale cursor does nothing")
    func staleCursor() {
        #expect(act(.left, cursor: 1, tiles: 0) == .none)
        #expect(act(.up, cursor: nil, tiles: 0, firstRow: true) == .none)
        #expect(act(.left, cursor: 5, tiles: 3) == .none)
    }

    @Test("a selected tile is accent only while the shelf has the keyboard in the key window")
    func selectionLook() {
        #expect(RecentShelfRules.selectionLook(isSelected: false, hasFocus: true, windowIsKey: true) == .none)
        #expect(RecentShelfRules.selectionLook(isSelected: true, hasFocus: true, windowIsKey: true) == .active)
        #expect(RecentShelfRules.selectionLook(isSelected: true, hasFocus: false, windowIsKey: true) == .inactive)
        #expect(RecentShelfRules.selectionLook(isSelected: true, hasFocus: true, windowIsKey: false) == .inactive)
    }

    @Test("a shelf entry is reached like a row by the selection, the File menu and a drag")
    func shelfEntriesAreSelectable() {
        let rows = (0..<5).map { entry($0) }
        let shelved = rows.prefix(2).map { LibraryRowDisplay(entry: $0) }
        let items = LibraryListItem.items(for: LibraryDateGroups.ungrouped(rows.dropFirst(2).map { LibraryRowDisplay(entry: $0) }))
        let picked = LibraryRowsTarget.selectedEntries(["e1", "e3"], in: items, shelf: shelved)
        #expect(picked.map(\.id) == ["e1", "e3"])
        #expect(LibraryRowsTarget.selectedEntries(["e1"], in: items).isEmpty)
    }

    @Test("the list drops a tile from its selection when a row is chosen with Command")
    func listSelectionDropsTiles() {
        let rows = (2..<5).map { LibraryRowDisplay(entry: entry($0)) }
        let items = LibraryListItem.items(for: LibraryDateGroups.ungrouped(rows))
        #expect(LibraryListItem.entries(in: ["e0", "e3"], items: items) == ["e3"])
    }

    @Test("date groups become sections, and entries before any title keep a section of their own")
    func sectionsFollowTheTitles() {
        let rows = (0..<4).map { LibraryRowDisplay(entry: entry($0)) }
        let items: [LibraryListItem] = [
            .entry(rows[0]), .header(id: "a", title: "Today"), .entry(rows[1]), .entry(rows[2]),
            .header(id: "b", title: "May"), .entry(rows[3]),
        ]
        let sections = LibraryListSection.sections(for: items)
        #expect(sections.map(\.title) == [nil, "Today", "May"])
        #expect(sections.map { $0.rows.map(\.id) } == [["e0"], ["e1", "e2"], ["e3"]])
        #expect(LibraryListSection.sections(for: []).isEmpty)
    }
}
