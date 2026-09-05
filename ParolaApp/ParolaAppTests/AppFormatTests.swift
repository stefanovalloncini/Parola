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

    @Test("sizes carry a unit and a separator, not raw bytes")
    func sizesCarryAUnit() {
        let label = AppFormat.byteSize(76_700_000, locale: Locale(identifier: "en_US"))
        #expect(label.hasSuffix("MB"))
        #expect(label.contains("76.7"))
    }
}
