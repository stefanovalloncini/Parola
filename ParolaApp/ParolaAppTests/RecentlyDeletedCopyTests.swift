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

    @Test("the bulk actions count what they will act on")
    func selectionActionLabels() {
        #expect(RecentlyDeletedCopy.restoreSelection(1) == "Restore (1)")
        #expect(RecentlyDeletedCopy.restoreSelection(3) == "Restore (3)")
        #expect(RecentlyDeletedCopy.deleteSelection(1) == "Delete (1)…")
        #expect(RecentlyDeletedCopy.deleteSelection(3) == "Delete (3)…")
    }

    @Test("the bulk actions are localized to Italian")
    func selectionActionLabelsItalian() throws {
        let it = try italianBundle()
        #expect(RecentlyDeletedCopy.restoreSelection(2, bundle: it) == "Ripristina (2)")
        #expect(RecentlyDeletedCopy.deleteSelection(2, bundle: it) == "Elimina (2)…")
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

    @Test("the subtitle names the count and the retention window")
    func subtitleWording() {
        #expect(RecentlyDeletedCopy.subtitle(count: 1, retentionDays: 30) == "1 item · removed after 30 days")
        #expect(RecentlyDeletedCopy.subtitle(count: 2, retentionDays: 30) == "2 items · removed after 30 days")
        #expect(RecentlyDeletedCopy.subtitle(count: 8, retentionDays: 14) == "8 items · removed after 14 days")
    }

    /// The two captions stack on the same page, so they have to read as a pair.
    @Test("the expiry captions are parallel in Italian")
    func bucketCaptionsItalian() throws {
        let it = try italianBundle()
        #expect(it.localizedString(forKey: RecentlyDeletedCopy.ExpiryBucket.soon.caption, value: "MISSING", table: nil) == "In scadenza")
        #expect(it.localizedString(forKey: RecentlyDeletedCopy.ExpiryBucket.later.caption, value: "MISSING", table: nil) == "In scadenza più avanti")
    }

    @Test("an empty trash leaves the retention window to the empty state")
    func subtitleEmpty() {
        #expect(RecentlyDeletedCopy.subtitle(count: 0, retentionDays: 30) == nil, "the empty state already states the window")
    }

    @Test("the subtitle is localized to Italian on both sides of zero")
    func subtitleWordingItalian() throws {
        let it = try italianBundle()
        #expect(RecentlyDeletedCopy.subtitle(count: 1, retentionDays: 30, bundle: it) == "1 elemento · rimosso dopo 30 giorni")
        #expect(RecentlyDeletedCopy.subtitle(count: 3, retentionDays: 30, bundle: it) == "3 elementi · rimossi dopo 30 giorni")
        #expect(RecentlyDeletedCopy.subtitle(count: 0, retentionDays: 30, bundle: it) == nil)
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

    @Test("the sections split on the third day")
    func bucketBoundary() {
        #expect(RecentlyDeletedCopy.bucket(daysLeft: -1) == .soon)
        #expect(RecentlyDeletedCopy.bucket(daysLeft: 0) == .soon)
        #expect(RecentlyDeletedCopy.bucket(daysLeft: 3) == .soon)
        #expect(RecentlyDeletedCopy.bucket(daysLeft: 4) == .later)
        #expect(RecentlyDeletedCopy.bucket(daysLeft: 30) == .later)
    }

    @Test("an item with no deletion date expires later, not soon")
    func bucketUndated() {
        #expect(RecentlyDeletedCopy.bucket(daysLeft: nil) == .later)
    }

    @Test("grouping leads with the urgent bucket and skips the empty one")
    func grouping() {
        let mixed = RecentlyDeletedCopy.grouped([12, 2, 30, 0]) { $0 }
        #expect(mixed.map(\.bucket) == [.soon, .later])
        #expect(mixed[0].items == [2, 0])
        #expect(mixed[1].items == [12, 30])

        let calmOnly = RecentlyDeletedCopy.grouped([12, 30]) { $0 }
        #expect(calmOnly.map(\.bucket) == [.later])
        #expect(RecentlyDeletedCopy.grouped([Int]()) { $0 }.isEmpty)
    }

    @Test("the expiry bar reads the share of the window that is left")
    func remainingFraction() {
        #expect(RecentlyDeletedCopy.remainingFraction(daysLeft: 30, retentionDays: 30) == 1)
        #expect(RecentlyDeletedCopy.remainingFraction(daysLeft: 15, retentionDays: 30) == 0.5)
        #expect(RecentlyDeletedCopy.remainingFraction(daysLeft: -4, retentionDays: 30) == 0)
        #expect(RecentlyDeletedCopy.remainingFraction(daysLeft: nil, retentionDays: 30) == nil)
    }

    @Test("the date slot names the deletion instead of leaving a bare day")
    func deletedOnLabel() throws {
        let deletedAt = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 12)))
        let label = try #require(RecentlyDeletedCopy.deletedOn(deletedAt))
        #expect(label == "Deleted \(AppFormat.dayAndMonth(deletedAt))")
        #expect(label.hasPrefix("Deleted "))
        #expect(RecentlyDeletedCopy.deletedOn(nil) == nil)
    }

    @Test("the date slot is localized to Italian")
    func deletedOnItalian() throws {
        let deletedAt = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 12)))
        let label = try #require(RecentlyDeletedCopy.deletedOn(deletedAt, bundle: try italianBundle()))
        #expect(label.hasPrefix("Eliminato il "))
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

@Suite("Recently Deleted search")
struct RecentlyDeletedSearchTests {
    @Test("a row whose preview never decoded is still reachable by its title")
    func titleMatchesWithoutAPreview() {
        #expect(RecentlyDeletedCopy.matches(query: "board", title: "Board meeting", preview: nil))
        #expect(!RecentlyDeletedCopy.matches(query: "budget", title: "Board meeting", preview: nil))
    }

    @Test("a decoded preview answers for what the title does not say")
    func previewMatchesTheTranscript() {
        #expect(RecentlyDeletedCopy.matches(query: "budget", title: "Board meeting", preview: "we went over the budget"))
    }

    @Test("the match ignores case on both sides")
    func matchIgnoresCase() {
        #expect(RecentlyDeletedCopy.matches(query: "BOARD", title: "Board meeting", preview: nil))
        #expect(RecentlyDeletedCopy.matches(query: "Budget", title: "Board meeting", preview: "the BUDGET again"))
    }

    @Test("an empty query keeps every row")
    func emptyQueryKeepsEverything() {
        #expect(RecentlyDeletedCopy.matches(query: "", title: "Board meeting", preview: nil))
    }
}
