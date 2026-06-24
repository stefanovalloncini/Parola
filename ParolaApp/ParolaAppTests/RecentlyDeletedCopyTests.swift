import Foundation
import Testing
@testable import Parola

@Suite("Recently Deleted count copy")
struct RecentlyDeletedCopyTests {
    private func italianBundle() throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test("bulk-purge title uses the singular noun for one item")
    func bulkPurgeSingular() {
        #expect(RecentlyDeletedCopy.bulkPurgeTitle(1) == "Delete 1 item permanently?")
    }

    @Test("bulk-purge title uses the plural noun for several items")
    func bulkPurgePlural() {
        #expect(RecentlyDeletedCopy.bulkPurgeTitle(3) == "Delete 3 items permanently?")
    }

    @Test("empty-trash message uses the singular noun for one item")
    func emptySingular() {
        #expect(RecentlyDeletedCopy.emptyTrashMessage(1) == "1 item will be deleted for good.")
    }

    @Test("empty-trash message uses the plural noun for several items")
    func emptyPlural() {
        #expect(RecentlyDeletedCopy.emptyTrashMessage(5) == "All 5 items will be deleted for good.")
    }

    @Test("the singular bulk-purge title is localized to Italian")
    func bulkPurgeSingularItalian() throws {
        #expect(RecentlyDeletedCopy.bulkPurgeTitle(1, bundle: try italianBundle()) == "Eliminare 1 elemento definitivamente?")
    }

    @Test("the singular empty-trash message is localized to Italian")
    func emptySingularItalian() throws {
        #expect(RecentlyDeletedCopy.emptyTrashMessage(1, bundle: try italianBundle()) == "1 elemento sarà eliminato per sempre.")
    }

    @Test("selection count uses the bare singular for one item")
    func selectionCountSingular() {
        #expect(RecentlyDeletedCopy.selectionCount(1) == "1 selected")
    }

    @Test("selection count uses the plural for several items")
    func selectionCountPlural() {
        #expect(RecentlyDeletedCopy.selectionCount(3) == "3 selected")
    }

    @Test("the singular selection count is localized to Italian")
    func selectionCountSingularItalian() throws {
        #expect(RecentlyDeletedCopy.selectionCount(1, bundle: try italianBundle()) == "1 selezionato")
    }

    @Test("the plural selection count is localized to Italian")
    func selectionCountPluralItalian() throws {
        #expect(RecentlyDeletedCopy.selectionCount(4, bundle: try italianBundle()) == "4 selezionati")
    }

    @Test("every sort label resolves to Italian")
    func sortLabelsItalian() throws {
        let it = try italianBundle()
        let expected: [RecentlyDeletedSort: String] = [
            .recentlyDeleted: "Eliminati di recente",
            .deletedEarliest: "Eliminati per primi",
            .titleAZ: "Titolo A→Z",
            .titleZA: "Titolo Z→A",
        ]
        for option in RecentlyDeletedSort.allCases {
            #expect(it.localizedString(forKey: option.title, value: "MISSING", table: nil) == expected[option])
        }
    }
}
