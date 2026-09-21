import Foundation
import Testing
@testable import ParolaCore

@Suite("Export content modes")
struct ExportContentTests {

    private func transcript(translating: [Int: String] = [0: "Good morning.", 1: "How did it go?"]) -> Transcript {
        var transcript = Transcript(
            segments: [
                TranscriptSegment(
                    id: 0, start: 0, end: 3, text: "Buongiorno.", speaker: "Ada",
                    words: [WordTiming(id: "0-0", word: "Buongiorno.", start: 0, end: 3, probability: 0.9)]
                ),
                TranscriptSegment(id: 1, start: 3, end: 6, text: "Com'è andata?", speaker: "Grace"),
            ],
            language: "it",
            modelName: "tiny"
        )
        transcript.translation = TranscriptTranslation(
            targetLanguage: "en",
            segments: translating,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            provider: "mock"
        )
        return transcript
    }

    private func render(_ format: ExportFormat, _ content: ExportContent, grouping: ExportGrouping = .none, _ transcript: Transcript) throws -> String {
        var options = ExportSpec.standard(for: format).options
        options.content = content
        options.grouping = grouping
        return try Exporters.exporter(for: ExportSpec(style: .style(for: format), format: format, options: options))
            .renderText(transcript)
    }

    @Test("the original export ignores the translation")
    func originalIgnoresTheTranslation() throws {
        #expect(try render(.txt, .original, transcript()) == "Ada: Buongiorno.\nGrace: Com'è andata?\n")
        #expect(try !render(.json, .original, transcript()).contains("translation"))
    }

    @Test("the translated export replaces each segment's text")
    func translationReplacesText() throws {
        #expect(try render(.txt, .translation, transcript()) == "Ada: Good morning.\nGrace: How did it go?\n")
    }

    @Test("a segment with no translation keeps its original text")
    func untranslatedSegmentsKeepTheOriginal() throws {
        let text = try render(.txt, .translation, transcript(translating: [1: "How did it go?"]))

        #expect(text == "Ada: Buongiorno.\nGrace: How did it go?\n")
    }

    @Test("both languages put the translation under the original")
    func bothWritesTwoLines() throws {
        #expect(try render(.txt, .both, transcript()) == """
        Ada: Buongiorno.
        Good morning.
        Grace: Com'è andata?
        How did it go?

        """)
    }

    @Test("markdown keeps both languages in one paragraph")
    func markdownBoth() throws {
        let text = try render(.md, .both, transcript())

        #expect(text.contains("**Ada:** Buongiorno.  \nGood morning.\n\n"))
        #expect(text.contains("**Grace:** Com'è andata?  \nHow did it go?"))
    }

    @Test("a subtitle cue carries both lines")
    func subtitleBoth() throws {
        let srt = try render(.srt, .both, transcript())

        #expect(srt.contains("Buongiorno.\nGood morning.\n\n"))
        #expect(try render(.srt, .translation, transcript()).contains("Good morning.\n\n"))
    }

    @Test("a WebVTT cue carries both lines inside the speaker tag")
    func vttBoth() throws {
        var options = ExportSpec.standard(for: .vtt).options
        options.content = .both
        options.speakers = true
        let vtt = try Exporters.exporter(for: ExportSpec(style: .subtitles, format: .vtt, options: options))
            .renderText(transcript())

        #expect(vtt.contains("<v Ada>Buongiorno.\nGood morning.</v>"))
    }

    @Test("html separates the two languages with a line break")
    func htmlBoth() throws {
        let html = try render(.html, .both, transcript())

        #expect(html.contains("Buongiorno.<br><span class=\"x\">Good morning.</span></p>"))
    }

    @Test("lrc repeats the timestamp for the translated line")
    func lrcBoth() throws {
        #expect(try render(.lrc, .both, transcript()).hasPrefix("[00:00.00]Buongiorno.\n[00:00.00]Good morning.\n"))
    }

    @Test("csv gains a translation column only when both languages are written")
    func csvBoth() throws {
        let csv = try render(.csv, .both, transcript())

        #expect(csv.hasPrefix("start_seconds,end_seconds,speaker,text,translation\n"))
        #expect(csv.contains("Ada,Buongiorno.,Good morning.\n"))
        #expect(try !render(.csv, .original, transcript()).contains("translation"))
        #expect(try render(.csv, .translation, transcript()).contains("Ada,Good morning.\n"))
    }

    @Test("tsv gains the same column")
    func tsvBoth() throws {
        let tsv = try render(.tsv, .both, transcript())

        #expect(tsv.hasPrefix("start_seconds\tend_seconds\tspeaker\ttext\ttranslation\n"))
        #expect(tsv.contains("Ada\tBuongiorno.\tGood morning.\n"))
    }

    @Test("json keeps the translation alongside the segments")
    func jsonBoth() throws {
        let json = try render(.json, .both, transcript())

        #expect(json.contains("\"translation\""))
        #expect(json.contains("\"Good morning.\""))
        #expect(json.contains("\"Buongiorno.\""))
    }

    @Test("the translated json replaces the text and drops the word timings that no longer fit")
    func jsonTranslation() throws {
        let json = try render(.json, .translation, transcript())

        #expect(json.contains("\"Good morning.\""))
        #expect(!json.contains("\"Buongiorno.\""))
        #expect(!json.contains("\"words\""))
    }

    @Test("each json line carries its own translation")
    func jsonLinesBoth() throws {
        let lines = try render(.jsonl, .both, transcript()).split(separator: "\n")

        #expect(lines.count == 2)
        #expect(lines[0].contains("\"translation\":\"Good morning.\""))
        #expect(lines[1].contains("\"translation\":\"How did it go?\""))
    }

    @Test("a final cut caption carries one language, so both means the translation")
    func fcpxmlBothIsTheTranslation() throws {
        #expect(try render(.fcpxml, .both, transcript()) == render(.fcpxml, .translation, transcript()))
        #expect(try render(.fcpxml, .both, transcript()).contains("Good morning."))
    }

    @Test("grouping merges translations the way it merges texts")
    func groupingMergesTranslations() throws {
        var t = transcript()
        t.segments[1].speaker = "Ada"
        t.segments[1].words = nil
        t.segments[0].words = nil

        #expect(try render(.txt, .translation, grouping: .speakerParagraphs, t)
            == "Ada: Good morning. How did it go?\n")
        #expect(try render(.txt, .both, grouping: .speakerParagraphs, t)
            == "Ada: Buongiorno. Com'è andata?\nGood morning. How did it go?\n")
    }

    @Test("an untranslated transcript renders the same whatever the content mode", arguments: ExportContent.allCases)
    func untranslatedTranscriptIsUnaffected(_ content: ExportContent) throws {
        let plain = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello.", speaker: "Ada")],
            language: "en",
            modelName: "tiny"
        )

        #expect(try render(.txt, content, plain) == "Ada: Hello.\n")
    }
}
