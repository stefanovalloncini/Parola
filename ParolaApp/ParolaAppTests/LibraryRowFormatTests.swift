import Foundation
import Testing
@testable import Parola

@Suite("Library row format")
struct LibraryRowFormatTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        return calendar
    }()
    private let english = Locale(identifier: "en_US")

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private var now: Date { date(2026, 9, 30, 10) }

    @Test("this morning is Today and late last night is Yesterday")
    func todayAndYesterday() {
        #expect(LibraryDateGroups.bucket(for: date(2026, 9, 30, 0, 1), now: now, calendar: calendar) == .today)
        #expect(LibraryDateGroups.bucket(for: date(2026, 9, 29, 23, 59), now: now, calendar: calendar) == .yesterday)
    }

    @Test("Previous 7 Days ends at midnight seven days back")
    func weekEdge() {
        #expect(LibraryDateGroups.bucket(for: date(2026, 9, 23, 0, 0), now: now, calendar: calendar) == .previousWeek)
        #expect(LibraryDateGroups.bucket(for: date(2026, 9, 22, 23, 59), now: now, calendar: calendar) == .previousMonth)
    }

    @Test("older takes group by month, naming the year only when it isn't this one")
    func months() {
        let august = LibraryDateGroups.bucket(for: date(2026, 8, 20), now: now, calendar: calendar)
        #expect(august == .month(year: 2026, month: 8))
        #expect(LibraryDateGroups.title(for: august, now: now, calendar: calendar, locale: english) == "August")
        let december = LibraryDateGroups.bucket(for: date(2025, 12, 3), now: now, calendar: calendar)
        #expect(LibraryDateGroups.title(for: december, now: now, calendar: calendar, locale: english) == "December 2025")
    }

    @Test("lengths read as words, never as a clock")
    func durationWords() {
        #expect(LibraryRowFormat.duration(nil) == nil)
        #expect(LibraryRowFormat.duration(0) == nil)
        #expect(LibraryRowFormat.duration(0.4) == "1 s")
        #expect(LibraryRowFormat.duration(8) == "8 s")
        #expect(LibraryRowFormat.duration(59.9) == "59 s")
        #expect(LibraryRowFormat.duration(60) == "1 min")
        #expect(LibraryRowFormat.duration(38 * 60 + 20) == "38 min")
        #expect(LibraryRowFormat.duration(3600) == "1 h")
        #expect(LibraryRowFormat.duration(4320) == "1 h 12 min")
    }

    /// A damaged manifest can carry any number; converting infinity to a count of seconds would trap.
    @Test("a length that isn't a real number shows nothing")
    func durationOfNonsense() {
        #expect(LibraryRowFormat.duration(.infinity) == nil)
        #expect(LibraryRowFormat.duration(.nan) == nil)
        #expect(LibraryRowFormat.duration(-5) == nil)
        #expect(LibraryRowFormat.subtitle(count: 2, totalSeconds: .infinity) == "2 transcripts")
    }

    @Test("a row under Today shows the time; under an older header, weekday or date")
    func whenUnderHeaders() {
        let morning = date(2026, 9, 30, 9, 5)
        let time = LibraryRowFormat.when(morning, under: .today, now: now, calendar: calendar, locale: english)
        #expect(time.hasPrefix("9:05"))
        #expect(time.hasSuffix("AM"))
        let friday = date(2026, 9, 25, 16, 40)
        #expect(LibraryRowFormat.when(friday, under: .previousWeek, now: now, calendar: calendar, locale: english)
            .hasPrefix("Fri"))
        let pinned = date(2026, 9, 29, 18, 0)
        #expect(LibraryRowFormat.when(pinned, under: nil, now: now, calendar: calendar, locale: english)
            .hasPrefix("Yesterday"))
    }

    @Test("a short time drops the leading zero a 24-hour region's hour field would add")
    func shortTimesHaveNoLeadingZero() {
        let englishInItaly = Locale(identifier: "en_US@rg=itzzzz")
        let morning = date(2026, 9, 30, 9, 31)
        #expect(LibraryRowFormat.when(morning, under: .today, now: now, calendar: calendar, locale: englishInItaly) == "9:31")
        #expect(LibraryRowFormat.when(morning, under: nil, now: now, calendar: calendar, locale: englishInItaly) == "Today 9:31")
        let yesterday = date(2026, 9, 29, 9, 31)
        #expect(LibraryRowFormat.when(yesterday, under: .yesterday, now: now, calendar: calendar, locale: englishInItaly) == "9:31")
        #expect(LibraryRowFormat.when(yesterday, under: nil, now: now, calendar: calendar, locale: englishInItaly) == "Yesterday 9:31")
    }

    @Test("a Previous 7 Days row gives its weekday and the short time, with no leading zero")
    func weekRowsUseTheShortTime() {
        let morning = date(2026, 9, 25, 9, 33)
        let englishInItaly = Locale(identifier: "en_US@rg=itzzzz")
        #expect(LibraryRowFormat.when(morning, under: .previousWeek, now: now, calendar: calendar, locale: englishInItaly) == "Fri 9:33")
        #expect(LibraryRowFormat.when(morning, under: nil, now: now, calendar: calendar, locale: englishInItaly) == "Fri 9:33")
        let today = LibraryRowFormat.when(date(2026, 9, 30, 9, 33), under: .today, now: now, calendar: calendar, locale: englishInItaly)
        #expect(today == "9:33", "the same time a Today row shows")
        #expect(LibraryRowFormat.when(morning, under: .previousWeek, now: now, calendar: calendar, locale: Locale(identifier: "it_IT")) == "Ven 9:33")
    }

    @Test("under a month header a row gives its day, and the year only when it isn't this one")
    func whenUnderMonths() {
        let august = date(2026, 8, 20)
        #expect(LibraryRowFormat.when(august, under: .month(year: 2026, month: 8), now: now, calendar: calendar, locale: english)
            == "Aug 20")
        let december = date(2025, 12, 3)
        #expect(LibraryRowFormat.when(december, under: .month(year: 2025, month: 12), now: now, calendar: calendar, locale: english)
            == "Dec 3, 2025")
    }

    /// Italian writes weekdays in lower case mid-sentence; a label standing on its own starts with a capital.
    @Test("an Italian weekday stands on its own with a capital")
    func italianWeekday() {
        let friday = date(2026, 9, 25, 16, 40)
        let italian = Locale(identifier: "it_IT")
        #expect(LibraryRowFormat.when(friday, under: .previousWeek, now: now, calendar: calendar, locale: italian)
            == "Ven 16:40")
    }

    @Test("the usual language is the most common; a tie goes to the first code alphabetically")
    func usualLanguage() {
        #expect(LibraryRowFormat.usualLanguage(codes: ["en", "it", "en"]) == "en")
        #expect(LibraryRowFormat.usualLanguage(codes: ["it", "en"]) == "en")
        #expect(LibraryRowFormat.usualLanguage(codes: []) == nil)
    }

    @Test("the header subtitle counts transcripts and their total length")
    func subtitle() {
        #expect(LibraryRowFormat.subtitle(count: 14, totalSeconds: 7 * 3600 + 25 * 60) == "14 transcripts · 7 h 25 min")
        #expect(LibraryRowFormat.subtitle(count: 1, totalSeconds: 8) == "1 transcript · 8 s")
        #expect(LibraryRowFormat.subtitle(count: 3, totalSeconds: 0) == "3 transcripts")
    }

    @Test("the subtitle reads naturally in Italian")
    func italianSubtitle() throws {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let italian = try #require(Bundle(path: path))
        #expect(LibraryRowFormat.subtitle(count: 14, totalSeconds: 7 * 3600 + 25 * 60, bundle: italian)
            == "14 trascrizioni · 7 h 25 min")
        #expect(LibraryRowFormat.subtitle(count: 1, totalSeconds: 8, bundle: italian) == "1 trascrizione · 8 s")
    }

    @Test("a thousand entries group in one pass, in order")
    func thousandEntries() {
        let dates = (0..<1_000).map { now.addingTimeInterval(-Double($0) * 3 * 3600) }
        let buckets = dates.map { LibraryDateGroups.bucket(for: $0, now: now, calendar: calendar) }
        var seen: [LibraryDateBucket] = []
        for bucket in buckets where seen.last != bucket { seen.append(bucket) }
        #expect(Set(seen).count == seen.count)
    }
}
