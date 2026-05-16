import Foundation
import Testing
@testable import ParolaCore

@Suite("Exporters")
struct ExporterTests {
    private func sample() -> Transcript {
        Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0.0, end: 1.5, text: "Hello world."),
                TranscriptSegment(id: 1, start: 1.5, end: 4.0, text: " This is Parola."),
                TranscriptSegment(id: 2, start: 4.0, end: 7.25, text: " Goodbye."),
            ],
            language: "en",
            modelName: "openai_whisper-tiny",
            sourceURL: URL(fileURLWithPath: "/tmp/x.wav"),
            durationSeconds: 7.25
        )
    }

    @Test("txt joins segment lines")
    func txt() throws {
        let out = try TxtExporter().renderText(sample())
        #expect(out == "Hello world.\nThis is Parola.\nGoodbye.")
    }

    @Test("srt has indexed blocks with comma-millisecond timestamps")
    func srt() throws {
        let out = try SrtExporter().renderText(sample())
        #expect(out.hasPrefix("1\n00:00:00,000 --> 00:00:01,500\nHello world.\n\n"))
        #expect(out.contains("2\n00:00:01,500 --> 00:00:04,000\nThis is Parola."))
        #expect(out.contains("3\n00:00:04,000 --> 00:00:07,250\nGoodbye."))
    }

    @Test("vtt starts with WEBVTT and uses period millis")
    func vtt() throws {
        let out = try VttExporter().renderText(sample())
        #expect(out.hasPrefix("WEBVTT\n\n"))
        #expect(out.contains("00:00:00.000 --> 00:00:01.500"))
        #expect(out.contains("00:00:04.000 --> 00:00:07.250"))
    }

    @Test("json round-trips through Codable")
    func json() throws {
        let original = sample()
        let rendered = try JsonExporter().renderText(original)
        let data = Data(rendered.utf8)
        let decoded = try JSONDecoder().decode(Transcript.self, from: data)
        #expect(decoded == original)
    }

    @Test("srt timestamp formatting")
    func srtTimestamp() {
        #expect(SrtExporter.srtTimestamp(0) == "00:00:00,000")
        #expect(SrtExporter.srtTimestamp(3661.25) == "01:01:01,250")
        #expect(SrtExporter.srtTimestamp(-1) == "00:00:00,000")
    }

    private func sampleWithSpeakers() -> Transcript {
        Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0.0, end: 1.5, text: "Hello world.", speaker: "Speaker 1"),
                TranscriptSegment(id: 1, start: 1.5, end: 4.0, text: " This is Parola.", speaker: "Speaker 2"),
            ],
            language: "en",
            modelName: "openai_whisper-tiny"
        )
    }

    @Test("markdown default: paragraphs only, no timestamps, no speakers")
    func markdownDefault() throws {
        let out = try MarkdownExporter().renderText(sample())
        #expect(out == "Hello world.\n\nThis is Parola.\n\nGoodbye.\n")
    }

    @Test("markdown with timestamps adds italic [HH:MM:SS] prefix")
    func markdownTimestamps() throws {
        let exporter = MarkdownExporter(options: MarkdownOptions(showTimestamps: true))
        let out = try exporter.renderText(sample())
        #expect(out.contains("*[00:00:00]* Hello world."))
        #expect(out.contains("*[00:00:01]* This is Parola."))
        #expect(out.contains("*[00:00:04]* Goodbye."))
    }

    @Test("markdown with speakers adds bold prefix")
    func markdownSpeakers() throws {
        let out = try MarkdownExporter().renderText(sampleWithSpeakers())
        #expect(out.contains("**Speaker 1:** Hello world."))
        #expect(out.contains("**Speaker 2:** This is Parola."))
    }

    @Test("markdown with speakers + timestamps combines both prefixes")
    func markdownBoth() throws {
        let exporter = MarkdownExporter(options: MarkdownOptions(showTimestamps: true))
        let out = try exporter.renderText(sampleWithSpeakers())
        #expect(out.contains("**Speaker 1** *[00:00:00]*: Hello world."))
        #expect(out.contains("**Speaker 2** *[00:00:01]*: This is Parola."))
    }

    @Test("md is a recognized ExportFormat with .md extension")
    func mdFormat() {
        #expect(ExportFormat.md.fileExtension == "md")
        #expect(Exporters.exporter(for: .md) is MarkdownExporter)
    }

    @Test("html starts with doctype and has a title")
    func htmlSkeleton() throws {
        let out = try HtmlExporter().renderText(sample())
        #expect(out.hasPrefix("<!DOCTYPE html>"))
        #expect(out.contains("<title>Transcript</title>"))
        #expect(out.hasSuffix("</html>"))
    }

    @Test("html has one paragraph per segment with anchored timestamp")
    func htmlSegments() throws {
        let out = try HtmlExporter().renderText(sample())
        #expect(out.contains("id=\"t-0\""))
        #expect(out.contains("href=\"#t-0\""))
        #expect(out.contains("[00:00:00]"))
        #expect(out.contains("Hello world."))
        #expect(out.contains("id=\"t-2\""))
    }

    @Test("html includes speaker prefix when present")
    func htmlSpeakers() throws {
        let out = try HtmlExporter().renderText(sampleWithSpeakers())
        #expect(out.contains("class=\"s\">Speaker 1</span>"))
        #expect(out.contains("class=\"s\">Speaker 2</span>"))
    }

    @Test("html escapes special characters")
    func htmlEscapes() throws {
        let transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "5 < 10 & \"true\"")],
            language: "en",
            modelName: "x"
        )
        let out = try HtmlExporter().renderText(transcript)
        #expect(out.contains("5 &lt; 10 &amp; &quot;true&quot;"))
    }

    @Test("html is a recognized ExportFormat")
    func htmlFormat() {
        #expect(ExportFormat.html.fileExtension == "html")
        #expect(Exporters.exporter(for: .html) is HtmlExporter)
    }

    @Test("csv has a header row")
    func csvHeader() throws {
        let out = try CsvExporter().renderText(sample())
        #expect(out.hasPrefix("start_seconds,end_seconds,speaker,text\n"))
    }

    @Test("csv emits one row per segment")
    func csvRows() throws {
        let out = try CsvExporter().renderText(sample())
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        // header + 3 segments
        #expect(lines.count >= 4)
        #expect(out.contains("0.0,1.5,,Hello world."))
    }

    @Test("csv quotes fields containing commas, quotes, newlines")
    func csvQuoting() throws {
        let transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: "hello, world"),
                TranscriptSegment(id: 1, start: 1, end: 2, text: "she said \"hi\""),
                TranscriptSegment(id: 2, start: 2, end: 3, text: "line1\nline2"),
            ],
            language: "en",
            modelName: "x"
        )
        let out = try CsvExporter().renderText(transcript)
        #expect(out.contains("\"hello, world\""))
        #expect(out.contains("\"she said \"\"hi\"\"\""))
        #expect(out.contains("\"line1\nline2\""))
    }

    @Test("csv emits empty speaker column when nil")
    func csvEmptySpeaker() throws {
        let out = try CsvExporter().renderText(sample())
        #expect(out.contains(",,"))   // empty speaker between start_seconds,end_seconds,,text
    }

    @Test("csv is a recognized ExportFormat")
    func csvFormat() {
        #expect(ExportFormat.csv.fileExtension == "csv")
        #expect(Exporters.exporter(for: .csv) is CsvExporter)
    }

    @Test("docx output starts with the PK ZIP signature")
    func docxIsZip() throws {
        let data = try DocxExporter().render(sample())
        #expect(data.count > 100)
        #expect(data[0] == 0x50 && data[1] == 0x4B && data[2] == 0x03 && data[3] == 0x04)
    }

    @Test("docx contains the OOXML namespace and segment text")
    func docxContent() throws {
        let data = try DocxExporter().render(sample())
        let asString = String(decoding: data, as: UTF8.self)
        #expect(asString.contains("xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\""))
        #expect(asString.contains("Hello world."))
        #expect(asString.contains("Goodbye."))
        #expect(asString.contains("[Content_Types].xml"))
    }

    @Test("docx wraps speakers in a bold run")
    func docxSpeakers() throws {
        let data = try DocxExporter().render(sampleWithSpeakers())
        let asString = String(decoding: data, as: UTF8.self)
        #expect(asString.contains("<w:rPr><w:b/></w:rPr>"))
        #expect(asString.contains("Speaker 1:"))
    }

    @Test("docx escapes XML-significant characters")
    func docxEscapes() throws {
        let transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "5 < 10 & true")],
            language: "en",
            modelName: "x"
        )
        let data = try DocxExporter().render(transcript)
        let asString = String(decoding: data, as: UTF8.self)
        #expect(asString.contains("5 &lt; 10 &amp; true"))
    }

    @Test("docx is a recognized ExportFormat")
    func docxFormat() {
        #expect(ExportFormat.docx.fileExtension == "docx")
        #expect(Exporters.exporter(for: .docx) is DocxExporter)
    }

    @Test("renderText throws for binary docx")
    func renderTextThrowsForBinary() throws {
        #expect(throws: Error.self) { _ = try DocxExporter().renderText(sample()) }
    }

    @Test("Zip.crc32 matches known values")
    func zipCrc32Known() {
        #expect(Zip.crc32(Data()) == 0)
        #expect(Zip.crc32(Data("123456789".utf8)) == 0xCBF43926)
    }
}
