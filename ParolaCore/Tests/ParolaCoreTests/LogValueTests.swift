import Foundation
import Testing
@testable import ParolaCore

@Suite("Log value")
struct LogValueTests {
    @Test("factories tag the kind and render the text")
    func factoriesRender() {
        #expect(LogValue.int(42).text == "42")
        #expect(LogValue.int(42).kind == .int)
        #expect(LogValue.bytes(2048).text == "2048")
        #expect(LogValue.bytes(2048).kind == .bytes)
        #expect(LogValue.flag(true).text == "true")
        #expect(LogValue.seconds(61.25).text == "61.25")
        #expect(LogValue.seconds(61.25).kind == .seconds)
    }

    @Test("safe wraps a LogSafe token")
    func safeWrapsToken() {
        #expect(LogValue.safe(EngineID.parakeet).text == "parakeet")
        #expect(LogValue.safe(ModelToken("openai_whisper-tiny")).text == "openai_whisper-tiny")
    }

    @Test("ids are truncated so they correlate without being unique handles")
    func idsTruncate() {
        let uuid = UUID(uuidString: "8F2C1A04-0000-0000-0000-000000000000")!
        #expect(LogValue.id(uuid).text == "8F2C1A04")
    }

    @Test("a duration renders as seconds")
    func durationRendersSeconds() {
        #expect(LogValue.duration(.milliseconds(1500)).text == "1.50")
    }

    @Test("seconds always carry two decimals, rounded away from zero")
    func secondsRenderTwoDecimals() {
        #expect(LogValue.seconds(0).text == "0.00")
        #expect(LogValue.seconds(1.2).text == "1.20")
        #expect(LogValue.seconds(0.005).text == "0.01")
        #expect(LogValue.seconds(3600.456).text == "3600.46")
        #expect(LogValue.seconds(99.999).text == "100.00")
        #expect(LogValue.seconds(-1.5).text == "-1.50")
        #expect(LogValue.seconds(0.125).text == "0.13")
    }

    @Test("a value too large or not finite renders without trapping")
    func extremeSecondsSurvive() {
        #expect(LogValue.seconds(1e19).text == "10000000000000000000.00")
        #expect(LogValue.seconds(.infinity).text == "inf")
        #expect(LogValue.seconds(-.infinity).text == "-inf")
        #expect(LogValue.seconds(.nan).text == "nan")
    }

    @Test("a Double log token renders with two decimals")
    func doubleTokenRendersTwoDecimals() {
        #expect(Double(0.5).logToken == "0.50")
        #expect(Double(-0.5).logToken == "-0.50")
        #expect(Double(12).logToken == "12.00")
    }

    @Test("fields sort deterministically for stable output")
    func fieldsSort() {
        let sorted = [LogField.model, .elapsed, .error].sorted()
        #expect(sorted == [.elapsed, .error, .model])
    }
}
