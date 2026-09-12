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

    @Test("a span picks the units that carry meaning and hides the rest")
    func durationPicksItsUnits() {
        let english = Locale(identifier: "en_US")
        #expect(AppFormat.duration(seconds: 0, locale: english) == nil)
        #expect(AppFormat.duration(seconds: -30, locale: english) == nil)
        #expect(AppFormat.duration(seconds: 0.4, locale: english) == nil)
        #expect(AppFormat.duration(seconds: 40, locale: english) == "40 sec")
        #expect(AppFormat.duration(seconds: 1_200, locale: english) == "20 min")
        #expect(AppFormat.duration(seconds: 7_200, locale: english) == "2 hr")
        #expect(AppFormat.duration(seconds: 4_800, locale: english) == "1 hr, 20 min")
    }

    @Test("sizes carry a unit and a separator, not raw bytes")
    func sizesCarryAUnit() {
        let label = AppFormat.byteSize(76_700_000, locale: Locale(identifier: "en_US"))
        #expect(label.hasSuffix("MB"))
        #expect(label.contains("76.7"))
    }
}
