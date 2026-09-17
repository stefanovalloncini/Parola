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
            .recentlyDeleted: "Più tempo rimasto",
            .deletedEarliest: "In scadenza per primi",
            .titleAZ: "Titolo A→Z",
            .titleZA: "Titolo Z→A",
        ]
        for option in RecentlyDeletedSort.allCases {
            #expect(it.localizedString(forKey: option.title, value: "MISSING", table: nil) == expected[option])
        }
    }

    @Test("the subtitle count uses the singular for one item")
    func subtitleCountSingular() {
        #expect(RecentlyDeletedCopy.subtitleCount(1) == "1 item")
    }

    @Test("the subtitle count uses the plural for several items")
    func subtitleCountPlural() {
        #expect(RecentlyDeletedCopy.subtitleCount(8) == "8 items")
    }

    @Test("the subtitle names the count and the retention window")
    func subtitleWording() {
        #expect(RecentlyDeletedCopy.subtitle(count: 1, retentionDays: 30) == "1 item · removed after 30 days")
        #expect(RecentlyDeletedCopy.subtitle(count: 2, retentionDays: 30) == "2 items · removed after 30 days")
        #expect(RecentlyDeletedCopy.subtitle(count: 8, retentionDays: 14) == "8 items · removed after 14 days")
    }

    @Test("an empty trash says so instead of counting to zero")
    func subtitleEmpty() {
        #expect(RecentlyDeletedCopy.subtitle(count: 0, retentionDays: 30) == "Nothing deleted · items are kept 30 days")
    }

    @Test("the subtitle is localized to Italian on both sides of zero")
    func subtitleWordingItalian() throws {
        let it = try italianBundle()
        #expect(RecentlyDeletedCopy.subtitle(count: 1, retentionDays: 30, bundle: it) == "1 elemento · rimossi dopo 30 giorni")
        #expect(RecentlyDeletedCopy.subtitle(count: 3, retentionDays: 30, bundle: it) == "3 elementi · rimossi dopo 30 giorni")
        #expect(RecentlyDeletedCopy.subtitle(count: 0, retentionDays: 30, bundle: it) == "Niente da eliminare · gli elementi restano 30 giorni")
    }

    @Test("an entry without a deletion date has no days left")
    func daysLeftUndated() throws {
        let now = try noon()
        #expect(RecentlyDeletedCopy.daysLeft(deletedAt: nil, now: now, retentionDays: 30) == nil)
    }

    @Test("days left counts down from the retention window")
    func daysLeftBoundaries() throws {
        let now = try noon()
        let expected: [Int: Int] = [0: 30, 22: 8, 23: 7, 27: 3, 28: 2, 29: 1, 30: 0, 31: -1, 45: -15]
        for (daysAgo, days) in expected {
            #expect(
                RecentlyDeletedCopy.daysLeft(deletedAt: deleted(daysAgo, before: now), now: now, retentionDays: 30) == days,
                "deleted \(daysAgo) days ago"
            )
        }
    }

    @Test("tiers split on the deadline thresholds")
    func tierMapping() {
        #expect(RecentlyDeletedCopy.tier(daysLeft: nil) == .undated)
        #expect(RecentlyDeletedCopy.tier(daysLeft: -1) == .overdue)
        #expect(RecentlyDeletedCopy.tier(daysLeft: 0) == .critical)
        #expect(RecentlyDeletedCopy.tier(daysLeft: 2) == .critical)
        #expect(RecentlyDeletedCopy.tier(daysLeft: 3) == .soon)
        #expect(RecentlyDeletedCopy.tier(daysLeft: 7) == .soon)
        #expect(RecentlyDeletedCopy.tier(daysLeft: 8) == .calm)
        #expect(RecentlyDeletedCopy.tier(daysLeft: 30) == .calm)
    }

    @Test("the countdown uses days above the final day")
    func timeLeftInDays() throws {
        let now = try noon()
        #expect(label(deleted(0, before: now), now) == "30 days left")
        #expect(label(deleted(28, before: now), now) == "2 days left")
        #expect(label(deleted(29, before: now), now) == "1 day left")
    }

    @Test("the countdown switches to hours on the final day")
    func timeLeftInHours() throws {
        let now = try noon()
        #expect(label(deleted(30, offsetHours: 5, before: now), now) == "5 hours left")
        #expect(label(deleted(30, offsetHours: 1.5, before: now), now) == "1 hour left")
        #expect(label(deleted(30, offsetHours: 0.5, before: now), now) == "Less than an hour left")
    }

    @Test("the countdown reports a missed deadline")
    func timeLeftPastDeadline() throws {
        let now = try noon()
        #expect(label(deleted(30, before: now), now) == "Past deadline")
        #expect(label(deleted(31, before: now), now) == "Past deadline")
    }

    @Test("an entry without a deletion date has no countdown")
    func timeLeftUndated() throws {
        let now = try noon()
        #expect(label(nil, now) == "No deadline")
    }

    @Test("the countdown is localized to Italian")
    func timeLeftItalian() throws {
        let now = try noon()
        let it = try italianBundle()
        #expect(label(deleted(23, before: now), now, bundle: it) == "7 giorni rimasti")
        #expect(label(deleted(29, before: now), now, bundle: it) == "1 giorno rimasto")
        #expect(label(deleted(30, offsetHours: 5, before: now), now, bundle: it) == "5 ore rimaste")
        #expect(label(deleted(31, before: now), now, bundle: it) == "Oltre la scadenza")
        #expect(label(nil, now, bundle: it) == "Senza scadenza")
    }

    @Test("the subtitle pieces are localized to Italian")
    func subtitleItalian() throws {
        let it = try italianBundle()
        #expect(RecentlyDeletedCopy.subtitleCount(1, bundle: it) == "1 elemento")
        #expect(RecentlyDeletedCopy.subtitleCount(8, bundle: it) == "8 elementi")
    }

    private func noon() throws -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 22
        components.hour = 12
        return try #require(Calendar.current.date(from: components))
    }

    private func deleted(_ daysAgo: Int, offsetHours: Double = 0, before now: Date) -> Date {
        now.addingTimeInterval(-Double(daysAgo) * 86_400 + offsetHours * 3_600)
    }

    private func label(_ deletedAt: Date?, _ now: Date, bundle: Bundle = .main) -> String {
        RecentlyDeletedCopy.timeLeftLabel(deletedAt: deletedAt, now: now, retentionDays: 30, bundle: bundle)
    }
}
