import Foundation
import Testing
@testable import Parola

@Suite("App formatting locale")
struct AppFormatTests {
    private let moment = Date(timeIntervalSince1970: 1_753_912_800)

    @Test("a size and the date beside it follow the injected locale")
    func sizeAndDateShareOneLocale() {
        let italian = Locale(identifier: "it_IT")
        #expect(AppFormat.byteSize(76_700_000, locale: italian).contains(","))
        #expect(AppFormat.dateAndTime(moment, locale: italian).contains("lug"))

        let american = Locale(identifier: "en_US")
        #expect(AppFormat.byteSize(76_700_000, locale: american).contains("."))
        #expect(AppFormat.dateAndTime(moment, locale: american).contains("Jul"))
    }

    @Test("every date style takes the same locale")
    func everyDateStyleTakesTheLocale() {
        let italian = Locale(identifier: "it_IT")
        #expect(AppFormat.longDateAndTime(moment, locale: italian).contains("luglio"))
        #expect(AppFormat.dayAndMonth(moment, locale: italian).contains("lug"))
        #expect(AppFormat.day(moment, locale: italian).contains("lug"))
    }

    /// R1 read "6,4 MB" beside "12 Sep 2026" as two locales on one card; both come from AppFormat,
    /// so the seam that decides it is the injected locale, not the call site.
    @Test("one locale drives every number on a card, whatever the system is set to")
    func oneLocaleDrivesTheWholeCard() {
        let english = Locale(identifier: "en_US")
        #expect(AppFormat.byteSize(6_400_000, locale: english) == "6.4 MB")
        #expect(AppFormat.byteSize(6_400_000, locale: Locale(identifier: "it_IT")) == "6,4 MB")
        #expect(AppFormat.percent(0.45, locale: english) == "45%")
        #expect(AppFormat.percent(0.455, fractionDigits: 1, locale: english) == "45.5%")
        #expect(AppFormat.percent(0.455, fractionDigits: 1, locale: Locale(identifier: "it_IT")) == "45,5%")
    }

    @Test("a count groups the way its locale groups")
    func countsTakeTheLocale() {
        #expect(AppFormat.integer(834, locale: Locale(identifier: "en_US")) == "834")
        #expect(AppFormat.integer(12_500, locale: Locale(identifier: "en_US")) == "12,500")
        #expect(AppFormat.integer(12_500, locale: Locale(identifier: "it_IT")) == "12.500")
        #expect(AppFormat.integer(0, locale: Locale(identifier: "en_US")) == "0")
    }

    @Test("a span picks the two largest units that carry meaning and hides the rest")
    func durationPicksItsUnits() {
        let english = Locale(identifier: "en_US")
        #expect(AppFormat.duration(seconds: 40, locale: english) == "40 sec")
        #expect(AppFormat.duration(seconds: 125, locale: english) == "2 min, 5 sec")
        #expect(AppFormat.duration(seconds: 1_200, locale: english) == "20 min")
        #expect(AppFormat.duration(seconds: 7_200, locale: english) == "2 hr")
        #expect(AppFormat.duration(seconds: 4_800, locale: english) == "1 hr, 20 min")
        #expect(AppFormat.duration(seconds: 12_500, locale: english) == "3 hr, 28 min")
    }

    /// Nothing and almost-nothing are different facts: one library has no audio, the other has a run too quick to round.
    @Test("a span shorter than a second says so, and a true zero says zero")
    func durationNamesTheSmallSpans() {
        let english = Locale(identifier: "en_US")
        #expect(AppFormat.duration(seconds: 0, locale: english) == "0 sec")
        #expect(AppFormat.duration(seconds: -30, locale: english) == "0 sec")
        #expect(AppFormat.duration(seconds: 0.4, locale: english) == "<1 sec")
        #expect(AppFormat.duration(seconds: 0.4, locale: Locale(identifier: "it_IT")).hasPrefix("<"))
    }

    @Test("a running clock reads m:ss under an hour and h:mm:ss from the hour on")
    func elapsedClock() {
        #expect(AppFormat.elapsed(0) == "0:00")
        #expect(AppFormat.elapsed(5.9) == "0:05")
        #expect(AppFormat.elapsed(59) == "0:59")
        #expect(AppFormat.elapsed(60) == "1:00")
        #expect(AppFormat.elapsed(754) == "12:34")
        #expect(AppFormat.elapsed(3_599) == "59:59")
        #expect(AppFormat.elapsed(3_600) == "1:00:00")
        #expect(AppFormat.elapsed(7_507) == "2:05:07")
        #expect(AppFormat.elapsed(36_000) == "10:00:00")
    }

    @Test("a clock never runs below zero or off a broken span")
    func elapsedClockHoldsAtZero() {
        #expect(AppFormat.elapsed(-3) == "0:00")
        #expect(AppFormat.elapsed(.infinity) == "0:00")
        #expect(AppFormat.elapsed(.nan) == "0:00")
    }

    @Test("sizes carry a unit and a separator, not raw bytes")
    func sizesCarryAUnit() {
        let label = AppFormat.byteSize(76_700_000, locale: Locale(identifier: "en_US"))
        #expect(label.hasSuffix("MB"))
        #expect(label.contains("76.7"))
    }
}
