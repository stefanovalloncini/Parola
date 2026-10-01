import Foundation
import Testing
import ParolaCore
@testable import Parola

@Suite("Library date groups")
struct LibraryDateGroupsTests {
    private static let rome = TimeZone(identifier: "Europe/Rome")!
    private static let english = Locale(identifier: "en_US")

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.rome
        calendar.locale = Self.english
        return calendar
    }

    /// "2026-09-13T09:30" in Rome, built through the same calendar the grouping reads.
    private func at(_ stamp: String) -> Date {
        let halves = stamp.split(separator: "T")
        let date = halves[0].split(separator: "-").compactMap { Int($0) }
        let time = halves[1].split(separator: ":").compactMap { Int($0) }
        var components = DateComponents()
        components.year = date[0]
        components.month = date[1]
        components.day = date[2]
        components.hour = time[0]
        components.minute = time[1]
        return calendar.date(from: components) ?? .distantPast
    }

    private func row(_ id: String, _ iso: String, pinned: Bool = false) -> LibraryRowDisplay {
        let manifest = ParolaDocument.Manifest(
            createdAt: at(iso),
            originalAudioName: "\(id).wav",
            title: id,
            modelName: "stub",
            language: "en",
            pinned: pinned
        )
        return LibraryRowDisplay(
            entry: LibraryEntry(
                id: id,
                bundleURL: URL(fileURLWithPath: "/tmp/LibraryDateGroupsTests/\(id).parola"),
                manifest: manifest
            )
        )
    }

    private func groups(_ rows: [LibraryRowDisplay], now: String, sortOrder: LibrarySortOrder = .newest) -> [LibraryDateGroups.Group] {
        LibraryDateGroups.groups(
            for: rows,
            sortOrder: sortOrder,
            now: at(now),
            calendar: calendar,
            locale: Self.english
        )
    }

    private var spread: [LibraryRowDisplay] {
        [
            row("today", "2026-09-30T09:30"),
            row("yesterday", "2026-09-29T23:10"),
            row("friday", "2026-09-25T08:00"),
            row("september", "2026-09-10T08:00"),
            row("late-august", "2026-08-20T08:00"),
            row("early-august", "2026-08-02T08:00"),
            row("last-december", "2025-12-03T08:00"),
        ]
    }

    @Test("rows read under Today, Yesterday, Previous 7 Days, Previous 30 Days, then one header per month")
    func headersReadLikeNotes() {
        let grouped = groups(spread, now: "2026-09-30T10:00")

        #expect(grouped.map(\.title) == [
            "Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "August", "December 2025",
        ])
        #expect(grouped.map { $0.rows.map(\.id) } == [
            ["today"], ["yesterday"], ["friday"], ["september"], ["late-august", "early-august"], ["last-december"],
        ])
    }

    @Test("oldest first reads the same headers the other way round")
    func oldestFirstReversesTheHeaders() {
        let grouped = groups(spread.reversed(), now: "2026-09-30T10:00", sortOrder: .oldest)

        #expect(grouped.map(\.title) == [
            "December 2025", "August", "Previous 30 Days", "Previous 7 Days", "Yesterday", "Today",
        ])
        #expect(grouped[1].rows.map(\.id) == ["early-august", "late-august"])
    }

    /// The day breaks at local midnight, not 24 hours back: 00:05 and 23:55 are different days an hour apart.
    @Test("a row a minute before midnight lands in the day it was made, not in today")
    func theBoundaryIsLocalMidnight() {
        let grouped = groups(
            [row("late", "2026-09-13T00:05"), row("earlier", "2026-09-12T23:55")],
            now: "2026-09-13T01:00"
        )

        #expect(grouped.map(\.title) == ["Today", "Yesterday"])
        #expect(grouped.first?.rows.map(\.id) == ["late"])
    }

    /// Pinned rows sort ahead of everything, so bucketing them would print one header twice.
    @Test("pinned rows keep their own group above the buckets")
    func pinnedRowsLeadWithoutBreakingTheBuckets() {
        let grouped = groups(
            [row("p", "2026-09-30T08:00", pinned: true), row("a", "2026-09-30T09:00"), row("b", "2026-09-29T09:00")],
            now: "2026-09-30T10:00"
        )

        #expect(grouped.map(\.title) == ["Pinned", "Today", "Yesterday"])
        #expect(grouped.map { $0.rows.map(\.id) } == [["p"], ["a"], ["b"]])
    }

    @Test("a sort that has nothing to do with dates runs under no header at all")
    func titleSortIsNotGrouped() {
        let rows = [row("a", "2026-09-13T09:00"), row("b", "2026-08-12T09:00")]
        let grouped = groups(rows, now: "2026-09-13T10:00", sortOrder: .titleAZ)

        #expect(grouped.count == 1)
        #expect(grouped.first?.title == nil)
        #expect(grouped.first?.rows.count == 2)
        #expect(LibraryDateGroups.groups(for: [], sortOrder: .newest).isEmpty)
    }

    @Test("a group is identified by its bucket, never by a formatted date")
    func groupIDsAreCheapAndStable() {
        let rows = [
            row("p", "2026-08-01T10:00", pinned: true),
            row("a", "2026-09-30T09:00"),
            row("b", "2026-09-30T08:00"),
            row("c", "2026-09-29T09:00"),
            row("d", "2026-08-20T09:00"),
        ]
        let first = groups(rows, now: "2026-09-30T10:00")
        let second = groups(rows, now: "2026-09-30T10:00")

        #expect(first.map(\.id) == ["pinned", "today", "yesterday", "month-2026-8"])
        #expect(first.map(\.id) == second.map(\.id))
        #expect(LibraryDateGroups.ungrouped(rows).first?.id == "all")
        #expect(LibraryDateGroups.ungrouped(rows, id: "results").first?.id == "results")
    }

    /// Headers are frozen when the groups are built, so a list left open over midnight has to rebuild them.
    @Test("the same rows read as Today before midnight and as Yesterday after it")
    func headersFollowTheDayTurningOver() {
        let rows = [row("a", "2026-09-29T23:50"), row("b", "2026-09-28T10:00")]
        let before = groups(rows, now: "2026-09-29T23:55")
        let after = groups(rows, now: "2026-09-30T00:05")

        #expect(before.map(\.title) == ["Today", "Yesterday"])
        #expect(after.map(\.title) == ["Yesterday", "Previous 7 Days"])
    }

    @Test("a month header takes the locale it is given, capitalised as a heading")
    func monthHeadersFollowTheLocale() {
        let august = LibraryDateBucket.month(year: 2026, month: 8)
        let now = at("2026-09-30T10:00")

        #expect(LibraryDateGroups.title(for: august, now: now, calendar: calendar, locale: Locale(identifier: "it_IT")) == "Agosto")
        #expect(LibraryDateGroups.title(for: august, now: now, calendar: calendar, locale: Self.english) == "August")
    }

    private func headers(
        now: String,
        sortOrder: LibrarySortOrder = .newest,
        groupsByDate: Bool = true
    ) -> LibraryDateGroups.Headers {
        LibraryDateGroups.Headers(
            sortOrder: sortOrder,
            groupsByDate: groupsByDate,
            now: at(now),
            calendar: calendar,
            locale: Self.english
        )
    }

    @Test("a row under a date header says only what the header leaves out; a pinned row names its day")
    func rowsSayWhatTheirHeaderLeavesOut() {
        let list = headers(now: "2026-09-30T10:00")
        let morning = list.when(for: row("a", "2026-09-30T09:05").entry)

        #expect(morning.hasPrefix("9:05"))
        #expect(morning.hasSuffix("AM"))
        #expect(list.when(for: row("friday", "2026-09-25T16:40").entry).hasPrefix("Fri"))
        #expect(list.when(for: row("p", "2026-09-29T18:00", pinned: true).entry).hasPrefix("Yesterday"))
    }

    @Test("the rows of a list say their times under the headers the list shows")
    func rowsAndHeadersAgree() {
        let list = headers(now: "2026-09-30T10:00")
        let rows = spread.map { LibraryRowDisplay(entry: $0.entry, when: list.when(for: $0.entry)) }
        let grouped = list.groups(for: rows)

        #expect(grouped.map(\.title) == [
            "Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "August", "December 2025",
        ])
        #expect(grouped[4].rows.map(\.when) == ["Aug 20", "Aug 2"])
        #expect(grouped[5].rows.map(\.when) == ["Dec 3, 2025"])
    }

    @Test("with grouping off the list runs under no header, and every row names its day")
    func groupingOffDropsTheHeaders() {
        let list = headers(now: "2026-09-30T10:00", groupsByDate: false)
        let rows = [row("a", "2026-09-30T09:05"), row("b", "2026-09-29T18:00")]
        let grouped = list.groups(for: rows)

        #expect(grouped.map(\.id) == ["all"])
        #expect(grouped.first?.title == nil)
        #expect(list.when(for: rows[0].entry).hasPrefix("Today"))
    }

    @Test("with grouping off, pinned rows lead under Pinned and the rest under Transcripts, as in Notes")
    func groupingOffKeepsPinned() {
        let list = headers(now: "2026-09-30T10:00", groupsByDate: false)
        let rows = [row("p", "2026-09-29T18:00", pinned: true), row("a", "2026-09-30T09:05"), row("b", "2026-08-02T09:00")]
        let grouped = list.groups(for: rows)

        #expect(grouped.map(\.id) == ["pinned", "all"])
        #expect(grouped.map(\.title) == ["Pinned", "Transcripts"])
        #expect(grouped.map { $0.rows.map(\.id) } == [["p"], ["a", "b"]])
    }

    @Test("an order that isn't by date keeps Pinned at the top, the rest under Transcripts")
    func undatedOrderKeepsPinned() {
        let rows = [row("z", "2026-09-29T18:00", pinned: true), row("a", "2026-09-30T09:05")]
        let grouped = groups(rows, now: "2026-09-30T10:00", sortOrder: .titleAZ)

        #expect(grouped.map(\.title) == ["Pinned", "Transcripts"])
        #expect(grouped.map { $0.rows.map(\.id) } == [["z"], ["a"]])
    }

    @Test("the header over the unpinned rows reads in Italian")
    func restHeaderInItalian() throws {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let italian = try #require(Bundle(path: path))
        #expect(String(localized: "Transcripts", bundle: italian) == "Trascrizioni")
    }

    @Test("a list of nothing but pins has only the Pinned group")
    func onlyPins() {
        let list = headers(now: "2026-09-30T10:00", groupsByDate: false)
        let grouped = list.groups(for: [row("p", "2026-09-29T18:00", pinned: true)])

        #expect(grouped.map(\.id) == ["pinned"])
    }

    @Test("an order that isn't by date names every row's day, grouping or not")
    func undatedOrderNamesEveryDay() {
        let list = headers(now: "2026-09-30T10:00", sortOrder: .titleAZ)
        let today = row("a", "2026-09-30T09:05")

        #expect(list.when(for: today.entry).hasPrefix("Today"))
        #expect(list.groups(for: [today]).map(\.title) == [nil])
    }

    @Test("a thousand entries reach the list's rows with the pins first, each header once over its own rows, every entry once")
    func thousandEntriesEndToEnd() throws {
        let now = at("2026-09-30T10:00")
        let entries: [LibraryEntry] = (0..<1_000).map { index in
            let manifest = ParolaDocument.Manifest(
                createdAt: now.addingTimeInterval(-Double(index) * 3 * 3600),
                originalAudioName: "take-\(index).m4a",
                title: "Take \(index)",
                modelName: "stub",
                language: index % 10 == 0 ? "it" : "en",
                labels: index % 3 == 0 ? ["Work"] : [],
                pinned: index % 97 == 5,
                durationSeconds: Double(60 + index)
            )
            return LibraryEntry(id: String(format: "%04d-scale", index), bundleURL: URL(fileURLWithPath: "/tmp/scale/\(index).parola"), manifest: manifest)
        }
        let clock = ContinuousClock()
        let start = clock.now
        let rows = LibraryListContent.rows(
            from: entries, category: nil, labelFilter: nil, languageFilter: nil, dateRange: .all, personFilter: nil
        )
        let headers = LibraryDateGroups.Headers(sortOrder: .newest, groupsByDate: true, now: now, calendar: calendar, locale: Self.english)
        var cache = LibraryRowDisplayCache()
        let displays = rows.map { cache.display(for: $0, when: headers.when(for: $0), usualLanguage: "EN") }
        let items = LibraryListItem.items(for: headers.groups(for: displays))
        let built = clock.now - start
        let regrouped = LibraryListItem.items(for: headers.groups(for: rows.map {
            cache.display(for: $0, when: headers.when(for: $0), usualLanguage: "EN")
        }))
        let rebuilt = clock.now - start - built
        print("SCALE 1,000 entries: \(items.count) list rows built in \(built), rebuilt from the cache in \(rebuilt)")

        let pinnedIDs = entries.filter(\.pinned).map(\.id)
        let unpinnedIDs = entries.filter { !$0.pinned }.map(\.id)
        var titles: [String] = []
        var entryIDs: [String] = []
        var misplaced: [String] = []
        for item in items {
            switch item {
            case .header(_, let title):
                titles.append(title)
            case .entry(let row):
                entryIDs.append(row.id)
                let bucket = LibraryDateGroups.bucket(for: row.entry.createdAt, now: now, calendar: calendar)
                let expected = row.pinned ? "Pinned" : LibraryDateGroups.title(for: bucket, now: now, calendar: calendar, locale: Self.english)
                if titles.last != expected { misplaced.append(row.id) }
            }
        }
        #expect(pinnedIDs.count == 11)
        #expect(titles.first == "Pinned")
        #expect(Array(titles.prefix(5)) == ["Pinned", "Today", "Yesterday", "Previous 7 Days", "Previous 30 Days"])
        #expect(Set(titles).count == titles.count, "a header shows up twice: \(titles)")
        #expect(Array(entryIDs.prefix(pinnedIDs.count)) == pinnedIDs, "the pins lead, in the library's order")
        #expect(Array(entryIDs.dropFirst(pinnedIDs.count)) == unpinnedIDs, "the rest keep newest first")
        #expect(misplaced.isEmpty, "rows under the wrong header: \(misplaced.prefix(5))")
        #expect(items.count == entries.count + titles.count)
        #expect(Set(items.map(\.id)).count == items.count, "every row of the list has an id of its own")
        #expect(regrouped == items, "a rebuild from the cache lands on the same rows")
        let italian = displays.filter { $0.language != nil }.count
        #expect(italian == 100, "only the rows in another language than the library's name it")
    }
}
