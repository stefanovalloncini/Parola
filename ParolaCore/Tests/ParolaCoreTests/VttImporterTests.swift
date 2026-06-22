import Foundation
import Testing
@testable import ParolaCore

@Suite("VTT importer")
struct VttImporterTests {
    @Test("parses sample.vtt fixture", .tags(.fileSystem))
    func sampleFixture() throws {
        let url = try #require(Bundle.module.url(forResource: "sample", withExtension: "vtt"))
        let raw = try String(contentsOf: url, encoding: .utf8)
        let t = VttImporter.parse(raw)
        #expect(t.segments.count == 3)
        #expect(t.segments[0].text == "Hello world.")
        #expect(t.segments[0].start == 0.0)
        #expect(t.segments[0].end == 1.5)
        #expect(t.segments[1].text == "This is a sample VTT file.")
        #expect(t.segments[2].text == "Goodbye world.")
        #expect(t.modelName == "youtube-subs")
    }

    @Test("parses a basic two-cue file")
    func basic() {
        let vtt = """
        WEBVTT

        00:00:00.000 --> 00:00:01.500
        Hello world.

        00:00:01.500 --> 00:00:03.000
        Goodbye world.
        """
        let t = VttImporter.parse(vtt)
        #expect(t.segments.count == 2)
        #expect(t.segments[0].text == "Hello world.")
        #expect(t.segments[0].start == 0.0)
        #expect(t.segments[0].end == 1.5)
        #expect(t.segments[1].text == "Goodbye world.")
        #expect(t.modelName == "youtube-subs")
    }

    @Test("ignores NOTE and STYLE blocks")
    func skipsNotes() {
        let vtt = """
        WEBVTT - YouTube

        NOTE This is a note
        that spans two lines

        STYLE
        ::cue { color: white }

        00:00:00.500 --> 00:00:02.000
        Real cue.
        """
        let t = VttImporter.parse(vtt)
        #expect(t.segments.count == 1)
        #expect(t.segments[0].text == "Real cue.")
    }

    @Test("ignores positioning attrs on the time line")
    func positioning() {
        let vtt = """
        WEBVTT

        00:00:00.000 --> 00:00:01.000 align:start position:10%
        Tagged cue.
        """
        let t = VttImporter.parse(vtt)
        #expect(t.segments.count == 1)
        #expect(t.segments[0].text == "Tagged cue.")
    }

    @Test("strips inline tags like <v Speaker> and <i>")
    func inlineTags() {
        #expect(SubtitleMarkup.stripInlineTags("<v Stefano>Hello there</v>") == "Hello there")
        #expect(SubtitleMarkup.stripInlineTags("Plain text") == "Plain text")
        #expect(SubtitleMarkup.stripInlineTags("<i>italic</i> normal") == "italic normal")
    }

    @Test("keeps an unclosed '<' as literal text instead of eating the line")
    func unclosedAngleBracket() {
        #expect(SubtitleMarkup.stripInlineTags("I love <3 you") == "I love <3 you")
        #expect(SubtitleMarkup.stripInlineTags("when x < 5 holds") == "when x < 5 holds")
        #expect(SubtitleMarkup.stripInlineTags("<i>tag</i> then x < 5") == "tag then x < 5")
    }

    @Test("accepts MM:SS.mmm without an hour field")
    func shortTimestamp() {
        let ts = VttImporter.parseTimestamp("01:30.500")
        #expect(ts == 90.5)
    }

    @Test("CRLF endings are handled")
    func crlf() {
        let vtt = "WEBVTT\r\n\r\n00:00:00.000 --> 00:00:01.000\r\nHi\r\n"
        let t = VttImporter.parse(vtt)
        #expect(t.segments.count == 1)
        #expect(t.segments[0].text == "Hi")
    }

    @Test("cues with optional identifier line are accepted")
    func cueIdentifier() {
        let vtt = """
        WEBVTT

        cue-1
        00:00:00.000 --> 00:00:01.500
        Hello.
        """
        let t = VttImporter.parse(vtt)
        #expect(t.segments.count == 1)
        #expect(t.segments.first?.text == "Hello.")
    }

    @Test("parses the first cue when no blank line follows the WEBVTT header")
    func parsesCueWithoutHeaderBlankLine() {
        let vtt = "WEBVTT\n00:00:01.000 --> 00:00:02.000\nHello"
        let t = VttImporter.parse(vtt)
        #expect(t.segments.count == 1)
        #expect(t.segments.first?.text == "Hello")
    }

    @Test("decodes HTML entities in cue text")
    func decodesEntities() {
        let vtt = """
        WEBVTT

        00:00:00.000 --> 00:00:02.000
        welcome to the Q&amp;A about rock &amp; roll
        """
        let t = VttImporter.parse(vtt)
        #expect(t.segments.first?.text == "welcome to the Q&A about rock & roll")
    }

    @Test("keeps escaped angle brackets as literals rather than dropping them as tags")
    func decodesAngleBrackets() {
        let vtt = """
        WEBVTT

        00:00:00.000 --> 00:00:02.000
        use &lt;b&gt; to make text bold
        """
        let t = VttImporter.parse(vtt)
        #expect(t.segments.first?.text == "use <b> to make text bold")
    }
}
