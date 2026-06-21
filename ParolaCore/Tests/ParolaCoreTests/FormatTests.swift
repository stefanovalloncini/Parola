import Foundation
import Testing
@testable import ParolaCore

@Suite("Format helpers")
struct FormatTests {
    @Test("parseClockTimestamp reads three-part HH:MM:SS.mmm")
    func parseThreePart() {
        #expect(Format.parseClockTimestamp("01:02:03.500") == 3723.5)
        #expect(Format.parseClockTimestamp("01:02:03") == 3723.0)
        #expect(Format.parseClockTimestamp("00:00:00.000") == 0.0)
    }

    @Test("parseClockTimestamp reads two-part MM:SS.mmm")
    func parseTwoPart() {
        #expect(Format.parseClockTimestamp("02:03.250") == 123.25)
        #expect(Format.parseClockTimestamp("00:05") == 5.0)
    }

    @Test("parseClockTimestamp treats comma as decimal point")
    func parseCommaDecimal() {
        #expect(Format.parseClockTimestamp("00:00:01,500") == 1.5)
        #expect(Format.parseClockTimestamp("00:01,5") == 1.5)
    }

    @Test("parseClockTimestamp trims surrounding whitespace")
    func parseTrimsWhitespace() {
        #expect(Format.parseClockTimestamp("  00:00:05.000  ") == 5.0)
        #expect(Format.parseClockTimestamp("\t01:00.0") == 60.0)
    }

    @Test("parseClockTimestamp keeps fractional seconds")
    func parseFractionalSeconds() {
        #expect(Format.parseClockTimestamp("00:00:07.250") == 7.25)
        #expect(Format.parseClockTimestamp("99:59:59.999") == 359_999.999)
    }

    @Test("parseClockTimestamp returns nil for malformed input", arguments: [
        "",
        "12",
        "ab:cd:ef",
        "1:2:3:4",
        "1.5:2:3",
        "01::03",
        "::",
    ])
    func parseRejectsMalformed(_ input: String) {
        #expect(Format.parseClockTimestamp(input) == nil)
    }

    @Test("parseClockTimestamp rejects non-finite and non-decimal seconds", arguments: [
        "00:00:nan",
        "00:00:inf",
        "00:00:1e3",
        "00:00:0x1p4",
        "00:00:-5",
        "00:nan",
        "00:1e3",
    ])
    func parseRejectsNonDecimalSeconds(_ input: String) {
        #expect(Format.parseClockTimestamp(input) == nil)
    }

    @Test("subtitleTimestamp uses the requested millisecond separator")
    func subtitleSeparator() {
        #expect(Format.subtitleTimestamp(1.5, msSeparator: ",") == "00:00:01,500")
        #expect(Format.subtitleTimestamp(1.5, msSeparator: ".") == "00:00:01.500")
    }

    @Test("subtitleTimestamp renders zero")
    func subtitleZero() {
        #expect(Format.subtitleTimestamp(0, msSeparator: ",") == "00:00:00,000")
    }

    @Test("subtitleTimestamp clamps negatives to zero")
    func subtitleNegativeClamps() {
        #expect(Format.subtitleTimestamp(-5, msSeparator: ",") == "00:00:00,000")
        #expect(Format.subtitleTimestamp(-0.5, msSeparator: ".") == "00:00:00.000")
    }

    @Test("subtitleTimestamp rounds at the millisecond boundary")
    func subtitleRounding() {
        #expect(Format.subtitleTimestamp(1.2345, msSeparator: ".") == "00:00:01.235")
        #expect(Format.subtitleTimestamp(1.2344, msSeparator: ".") == "00:00:01.234")
        #expect(Format.subtitleTimestamp(0.0005, msSeparator: ".") == "00:00:00.001")
    }

    @Test("subtitleTimestamp handles values past an hour")
    func subtitleOverAnHour() {
        #expect(Format.subtitleTimestamp(3661.25, msSeparator: ",") == "01:01:01,250")
    }

    @Test("subtitleTimestamp does not truncate hours past 99")
    func subtitleHugeHours() {
        #expect(Format.subtitleTimestamp(360_000, msSeparator: ".") == "100:00:00.000")
    }

    @Test("subtitleTimestamp saturates instead of trapping past Int range")
    func subtitleSaturatesOnOverflow() {
        let huge = Format.subtitleTimestamp(1e16, msSeparator: ",")
        #expect(huge.filter { $0 == ":" }.count == 2)
        let fields = huge.split(separator: ",")
        #expect(fields.count == 2)
        #expect(fields[1].count == 3)
    }

    @Test("timestampHHMMSS saturates instead of trapping past Int range")
    func timestampSaturatesOnOverflow() {
        #expect(Format.timestampHHMMSS(3661) == "01:01:01")
        let huge = Format.timestampHHMMSS(1e19)
        #expect(huge.filter { $0 == ":" }.count == 2)
        #expect(!huge.isEmpty)
    }

    @Test("escapeWebVTT escapes ampersand and angle brackets")
    func webvttEscapesMarkup() {
        #expect(Format.escapeWebVTT("a < b & c > d") == "a &lt; b &amp; c &gt; d")
        #expect(Format.escapeWebVTT("<i>x</i>") == "&lt;i&gt;x&lt;/i&gt;")
    }

    @Test("escapeWebVTT leaves quotes and apostrophes literal")
    func webvttKeepsQuotes() {
        #expect(Format.escapeWebVTT("don't say \"hi\"") == "don't say \"hi\"")
        #expect(Format.escapeWebVTT("\"'") == "\"'")
    }

    @Test("escapeWebVTT and escapeHTML differ on quotes")
    func webvttVersusHTML() {
        let input = "she said \"don't\""
        #expect(Format.escapeWebVTT(input) == input)
        #expect(Format.escapeHTML(input).contains("&quot;"))
        #expect(Format.escapeHTML(input).contains("&#39;"))
    }
}
