import Foundation
import Testing
@testable import ParolaCore

@Suite("SRT importer")
struct SrtImporterTests {
    @Test("parses sample.srt fixture", .tags(.fileSystem))
    func sampleFixture() throws {
        let url = try #require(Bundle.module.url(forResource: "sample", withExtension: "srt"))
        let raw = try String(contentsOf: url, encoding: .utf8)
        let t = SrtImporter.parse(raw)
        #expect(t.segments.count == 3)
        #expect(t.segments[0].text == "Hello world.")
        #expect(t.segments[0].start == 0.0)
        #expect(t.segments[0].end == 1.5)
        #expect(t.segments[1].text == "This is a sample SRT file.")
        #expect(t.segments[2].text == "Goodbye world.")
        #expect(t.segments[2].end == 4.8)
    }

    @Test("parses CRLF-encoded sample-crlf.srt fixture", .tags(.fileSystem))
    func crlfFixture() throws {
        let url = try #require(Bundle.module.url(forResource: "sample-crlf", withExtension: "srt"))
        let raw = try String(contentsOf: url, encoding: .utf8)
        let t = SrtImporter.parse(raw)
        #expect(t.segments.count == 2)
        #expect(t.segments[0].text == "Hello CRLF world.")
        #expect(t.segments[1].text == "Second cue.")
    }

    @Test("parses a two-block file")
    func twoBlocks() {
        let srt = """
        1
        00:00:00,000 --> 00:00:01,500
        Hello world.

        2
        00:00:01,500 --> 00:00:03,000
        Goodbye world.
        """
        let t = SrtImporter.parse(srt)
        #expect(t.segments.count == 2)
        #expect(t.segments[0].text == "Hello world.")
        #expect(t.segments[0].start == 0.0)
        #expect(t.segments[0].end == 1.5)
        #expect(t.segments[1].text == "Goodbye world.")
    }

    @Test("multi-line subtitle joins on single space")
    func multilineText() {
        let srt = """
        1
        00:00:00,000 --> 00:00:02,000
        First line
        Second line
        """
        let t = SrtImporter.parse(srt)
        #expect(t.segments.first?.text == "First line Second line")
    }

    @Test("CRLF endings are handled")
    func crlf() {
        let srt = "1\r\n00:00:00,000 --> 00:00:01,000\r\nHi\r\n"
        let t = SrtImporter.parse(srt)
        #expect(t.segments.count == 1)
        #expect(t.segments.first?.text == "Hi")
    }

    @Test("a leading BOM doesn't drop the first cue of a number-less SRT")
    func leadingBOM() {
        let srt = "\u{FEFF}00:00:00,000 --> 00:00:01,500\nHello world.\n\n00:00:01,500 --> 00:00:03,000\nGoodbye."
        let t = SrtImporter.parse(srt)
        #expect(t.segments.count == 2)
        #expect(t.segments.first?.text == "Hello world.")
        #expect(t.segments.first?.start == 0.0)
    }

    @Test("CR-only (classic Mac) endings are handled")
    func crOnly() {
        let srt = "1\r00:00:00,000 --> 00:00:01,000\rHi\r"
        let t = SrtImporter.parse(srt)
        #expect(t.segments.count == 1)
        #expect(t.segments.first?.text == "Hi")
    }

    @Test("timestamp with hours parses")
    func longTimestamp() {
        let ts = SrtImporter.parseTimestamp("01:02:03,500")
        #expect(ts == 3723.5)
    }

    @Test("MM:SS,mmm timestamp parses without an hour field")
    func shortTimestamp() {
        let ts = SrtImporter.parseTimestamp("01:30,500")
        #expect(ts == 90.5)
    }

    @Test("MM:SS encoder cues are not dropped")
    func mmssCue() {
        let srt = """
        1
        00:00,000 --> 00:01,500
        Short form.
        """
        let t = SrtImporter.parse(srt)
        #expect(t.segments.count == 1)
        #expect(t.segments.first?.text == "Short form.")
        #expect(t.segments.first?.start == 0.0)
        #expect(t.segments.first?.end == 1.5)
    }

    @Test("drops a cue whose timestamp is not finite")
    func dropsNonFiniteTimestampCue() {
        let srt = """
        1
        00:00:00,000 --> 00:00:01,000
        hello

        2
        00:00:nan --> 00:00:03,000
        poison

        3
        00:00:04,000 --> 00:00:05,000
        world
        """
        let t = SrtImporter.parse(srt)
        #expect(t.segments.count == 2)
        #expect(t.segments.map(\.text) == ["hello", "world"])
        #expect(t.segments.allSatisfy { $0.start.isFinite && $0.end.isFinite })
    }

    @Test("drops a cue whose timestamp is absurdly large")
    func dropsOutOfRangeTimestampCue() {
        let srt = """
        1
        00:00:00,000 --> 00:00:01,000
        hello

        2
        99999999999:00:00,000 --> 99999999999:00:01,000
        poison

        3
        00:00:04,000 --> 00:00:05,000
        world
        """
        let t = SrtImporter.parse(srt)
        #expect(t.segments.count == 2)
        #expect(t.segments.map(\.text) == ["hello", "world"])
    }

    @Test("strips inline formatting tags from cue text")
    func stripsInlineTags() {
        let srt = """
        1
        00:00:00,000 --> 00:00:02,000
        <i>Hello</i> <font color="#ff0000">world</font>.
        """
        let t = SrtImporter.parse(srt)
        #expect(t.segments.count == 1)
        #expect(t.segments.first?.text == "Hello world.")
    }

    @Test("strips a formatting tag spanning two text lines")
    func stripsTagAcrossLines() {
        let srt = """
        1
        00:00:00,000 --> 00:00:02,000
        <i>First line
        second line</i>
        """
        let t = SrtImporter.parse(srt)
        #expect(t.segments.first?.text == "First line second line")
    }

    @Test("durationSeconds is the max cue end on out-of-order input")
    func durationIsMaxEndOnOutOfOrder() {
        let srt = """
        1
        00:01:00,000 --> 00:01:05,000
        Early in file, late in time.

        2
        00:00:00,000 --> 00:00:03,000
        Late in file, early in time.
        """
        let t = SrtImporter.parse(srt)
        #expect(t.segments.count == 2)
        #expect(t.segments.last?.end == 65.0)
        #expect(t.durationSeconds == 65.0)
    }

    @Test("imports out-of-order cues in chronological order with sequential ids")
    func sortsOutOfOrderCues() {
        let srt = """
        1
        00:01:00,000 --> 00:01:05,000
        Early in file, late in time.

        2
        00:00:00,000 --> 00:00:03,000
        Late in file, early in time.
        """
        let t = SrtImporter.parse(srt)
        #expect(t.segments.map(\.start) == [0.0, 60.0])
        #expect(t.segments.map(\.text) == ["Late in file, early in time.", "Early in file, late in time."])
        #expect(t.segments.map(\.id) == [0, 1])
    }

    @Test("ignores SubRip positional coordinates on the time line")
    func positionalCoordinates() {
        let srt = """
        1
        00:00:00,000 --> 00:00:02,000 X1:100 X2:300 Y1:50 Y2:80
        Positioned cue.
        """
        let t = SrtImporter.parse(srt)
        #expect(t.segments.count == 1)
        #expect(t.segments.first?.text == "Positioned cue.")
        #expect(t.segments.first?.end == 2.0)
    }

    @Test("trims surrounding and collapses indented whitespace in cue text")
    func trimsWhitespace() {
        let srt = "1\n00:00:00,000 --> 00:00:02,000\n  First\n   Second  \n"
        let t = SrtImporter.parse(srt)
        #expect(t.segments.first?.text == "First Second")
    }

    @Test("skips a cue whose text is empty and keeps ids sequential")
    func skipsEmptyTextCue() {
        let srt = """
        1
        00:00:00,000 --> 00:00:01,000

        2
        00:00:01,000 --> 00:00:02,000
        Real text.
        """
        let t = SrtImporter.parse(srt)
        #expect(t.segments.count == 1)
        #expect(t.segments.first?.text == "Real text.")
        #expect(t.segments.first?.id == 0)
    }

    @Test("decodes the ampersand entity in cue text")
    func decodesAmpersandEntity() {
        let srt = """
        1
        00:00:00,000 --> 00:00:02,000
        Tom &amp; Jerry are back
        """
        let t = SrtImporter.parse(srt)
        #expect(t.segments.first?.text == "Tom & Jerry are back")
    }

    @Test("decodes the numeric apostrophe and quote entities in cue text")
    func decodesApostropheAndQuoteEntities() {
        let srt = """
        1
        00:00:00,000 --> 00:00:02,000
        she said &quot;it&#39;s fine&quot;
        """
        let t = SrtImporter.parse(srt)
        #expect(t.segments.first?.text == "she said \"it's fine\"")
    }

    @Test("keeps escaped angle brackets as literal text instead of stripping them as a tag")
    func keepsEscapedAngleBrackets() {
        let srt = """
        1
        00:00:00,000 --> 00:00:02,000
        use &lt;b&gt; to make text bold
        """
        let t = SrtImporter.parse(srt)
        #expect(t.segments.first?.text == "use <b> to make text bold")
    }

    @Test("keeps a double-escaped ampersand entity as a literal")
    func keepsDoubleEscapedAmpersand() {
        let srt = """
        1
        00:00:00,000 --> 00:00:02,000
        the entity &amp;#39; is written like this
        """
        let t = SrtImporter.parse(srt)
        #expect(t.segments.first?.text == "the entity &#39; is written like this")
    }
}
