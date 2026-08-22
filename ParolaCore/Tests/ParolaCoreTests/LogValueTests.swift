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
        #expect(LogValue.safe(ModelToken("v3")).text == "v3")
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

    @Test("fields sort deterministically for stable output")
    func fieldsSort() {
        let sorted = [LogField.model, .elapsed, .error].sorted()
        #expect(sorted == [.elapsed, .error, .model])
    }
}
