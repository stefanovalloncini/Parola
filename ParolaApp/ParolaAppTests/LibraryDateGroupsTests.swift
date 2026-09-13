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
            ),
            sizeBytes: nil
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

    @Test("today, yesterday and then the date itself")
    func headersReadAsDays() {
        let grouped = groups(
            [row("a", "2026-09-13T09:30"), row("b", "2026-09-12T23:10"), row("c", "2026-09-04T08:00")],
            now: "2026-09-13T10:00"
        )

        let older = AppFormat.day(at("2026-09-04T08:00"), locale: Self.english)
        #expect(grouped.map(\.title) == ["Today", "Yesterday", older])
        #expect(grouped.map { $0.rows.map(\.id) } == [["a"], ["b"], ["c"]])
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

    @Test("rows made on the same day share one header however many there are")
    func oneHeaderPerDay() {
        let grouped = groups(
            [row("a", "2026-09-11T18:00"), row("b", "2026-09-11T09:00"), row("c", "2026-09-10T09:00")],
            now: "2026-09-13T10:00"
        )

        #expect(grouped.count == 2)
        #expect(grouped.first?.rows.map(\.id) == ["a", "b"])
    }

    /// Pinned rows sort ahead of everything, so dating them would print one day's header twice.
    @Test("pinned rows keep their own group above the days")
    func pinnedRowsLeadWithoutBreakingTheDays() {
        let grouped = groups(
            [row("p", "2026-08-01T10:00", pinned: true), row("a", "2026-09-13T09:00"), row("b", "2026-09-12T09:00")],
            now: "2026-09-13T10:00"
        )

        #expect(grouped.map(\.title) == ["Pinned", "Today", "Yesterday"])
        #expect(grouped.map(\.showsTime) == [false, true, true])
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

    @Test("the header takes the locale it is given")
    func headersFollowTheLocale() {
        let day = at("2026-09-04T08:00")
        let italian = LibraryDateGroups.title(
            for: day,
            now: at("2026-09-13T10:00"),
            calendar: calendar,
            locale: Locale(identifier: "it_IT")
        )

        #expect(italian == AppFormat.day(day, locale: Locale(identifier: "it_IT")))
        #expect(italian != LibraryDateGroups.title(for: day, now: at("2026-09-13T10:00"), calendar: calendar, locale: Self.english))
    }

    /// Home hands the list its leftover space; a group header eats into it like a row does.
    @Test("trimming Home's rows counts the headers above them")
    func trimmingCountsHeaders() {
        let grouped = groups(
            [row("a", "2026-09-13T09:00"), row("b", "2026-09-12T09:00"), row("c", "2026-09-12T08:00")],
            now: "2026-09-13T10:00"
        )
        let trimmed = LibraryDateGroups.trimmed(grouped, toHeight: 160, rowHeight: 60, headerHeight: 20)

        #expect(trimmed.map { $0.rows.map(\.id) } == [["a"], ["b"]])
        #expect(LibraryDateGroups.trimmed(grouped, toHeight: 40, rowHeight: 60, headerHeight: 20)
            .map { $0.rows.map(\.id) } == [["a"]])
    }

    /// A tall window is not an invitation to render the whole library into Home's feed.
    @Test("a window with room to spare still stops at the maximum")
    func aTallWindowStopsAtTheMaximum() {
        let rows = (0..<40).map { row("e\($0)", "2026-09-13T09:00") }
        let trimmed = LibraryDateGroups.trimmed(
            groups(rows, now: "2026-09-13T10:00"),
            toHeight: 8000,
            rowHeight: 60,
            headerHeight: 20
        )

        #expect(trimmed.reduce(0) { $0 + $1.rows.count } == RecentEntries.homeMaximum)
        #expect(LibraryDateGroups.trimmed(
            groups(rows, now: "2026-09-13T10:00"),
            toHeight: 8000,
            rowHeight: 60,
            headerHeight: 20,
            atMost: 3
        ).reduce(0) { $0 + $1.rows.count } == 3)
    }

    /// Home measures its space one frame late; until it does, the list shows the count it always did.
    @Test("an unmeasured list falls back to a fixed number of rows")
    func unmeasuredHeightFallsBack() {
        let grouped = groups(
            [row("a", "2026-09-13T09:00"), row("b", "2026-09-12T09:00"), row("c", "2026-09-12T08:00")],
            now: "2026-09-13T10:00"
        )
        let fallback = LibraryDateGroups.trimmed(grouped, toHeight: 0, rowHeight: 60, headerHeight: 20, beforeMeasuring: 2)

        #expect(fallback.map { $0.rows.map(\.id) } == [["a"], ["b"]])
    }
}
