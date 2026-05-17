import Foundation
import Testing
@testable import ParolaCore

@Suite("SRT importer")
struct SrtImporterTests {
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
}
