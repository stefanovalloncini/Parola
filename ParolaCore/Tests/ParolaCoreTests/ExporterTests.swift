import Foundation
import PDFKit
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

    @Test("markdown treats an empty-string speaker as no speaker")
    func markdownEmptySpeaker() throws {
        let transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello.", speaker: "")],
            language: "en",
            modelName: "x"
        )
        let plain = try MarkdownExporter().renderText(transcript)
        #expect(plain == "Hello.\n")
        #expect(plain.contains("**:**") == false)

        let timed = try MarkdownExporter(options: MarkdownOptions(showTimestamps: true)).renderText(transcript)
        #expect(timed == "*[00:00:00]* Hello.\n")
        #expect(timed.contains("****") == false)
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

    @Test("html omits timestamps when showTimestamps is off")
    func htmlNoTimestamps() throws {
        let out = try HtmlExporter(options: HtmlOptions(showTimestamps: false)).renderText(sample())
        #expect(!out.contains("class=\"t\""))
        #expect(!out.contains("[00:00:00]"))
        #expect(out.contains("Hello world."))
        #expect(out.contains("id=\"t-0\""))
    }

    @Test("html includes speaker prefix when present")
    func htmlSpeakers() throws {
        let out = try HtmlExporter().renderText(sampleWithSpeakers())
        #expect(out.contains("class=\"s\">Speaker 1</span>"))
        #expect(out.contains("class=\"s\">Speaker 2</span>"))
    }

    @Test("html omits the speaker span for an empty-string speaker")
    func htmlEmptySpeaker() throws {
        let transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello.", speaker: "")],
            language: "en",
            modelName: "x"
        )
        let out = try HtmlExporter().renderText(transcript)
        #expect(out.contains("class=\"s\"") == false)
        #expect(out.contains("</span>:") == false)
        #expect(out.contains("Hello."))
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

    @Test("csv quotes a field containing a fused CRLF")
    func csvQuotesFusedCRLF() throws {
        let transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: "line1\r\nline2"),
            ],
            language: "en",
            modelName: "x"
        )
        let out = try CsvExporter().renderText(transcript)
        #expect(out.contains("\"line1\r\nline2\""))
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

    @Test("docx omits the bold speaker run for an empty-string speaker")
    func docxEmptySpeaker() throws {
        let transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello.", speaker: "")],
            language: "en",
            modelName: "x"
        )
        let data = try DocxExporter().render(transcript)
        let asString = String(decoding: data, as: UTF8.self)
        #expect(asString.contains("<w:rPr><w:b/></w:rPr>") == false)
        #expect(asString.contains(": </w:t>") == false)
        #expect(asString.contains("Hello."))
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
        #expect(throws: ParolaError.self) { _ = try DocxExporter().renderText(sample()) }
    }

    @Test("Zip.crc32 matches known values")
    func zipCrc32Known() {
        #expect(Zip.crc32(Data()) == 0)
        #expect(Zip.crc32(Data("123456789".utf8)) == 0xCBF43926)
    }

    @Test("pdf starts with the PDF magic")
    func pdfMagic() throws {
        let data = try PdfExporter().render(sample())
        let prefix = String(decoding: data.prefix(5), as: UTF8.self)
        #expect(prefix == "%PDF-")
    }

    @Test("pdf opens with PDFKit and has at least one page")
    func pdfOpens() throws {
        let data = try PdfExporter().render(sample())
        let doc = try #require(PDFDocument(data: data))
        #expect(doc.pageCount >= 1)
    }

    @Test("pdf contains the transcript text")
    func pdfContainsText() throws {
        let data = try PdfExporter().render(sample())
        let doc = try #require(PDFDocument(data: data))
        let text = (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: " ")
        #expect(text.contains("Hello world."))
        #expect(text.contains("Goodbye."))
    }

    @Test("pdf paginates long transcripts onto multiple pages")
    func pdfPaginates() throws {
        let lines = (0..<200).map { i in
            TranscriptSegment(id: i, start: Double(i), end: Double(i) + 0.5, text: "Line number \(i) of a long transcript that should overflow a single page.")
        }
        let transcript = Transcript(segments: lines, language: "en", modelName: "x")
        let data = try PdfExporter().render(transcript)
        let doc = try #require(PDFDocument(data: data))
        #expect(doc.pageCount > 1)
    }

    @Test("pdf is a recognized ExportFormat")
    func pdfFormat() {
        #expect(ExportFormat.pdf.fileExtension == "pdf")
        #expect(Exporters.exporter(for: .pdf) is PdfExporter)
    }

    @Test("renderText throws for binary pdf")
    func renderTextThrowsForPdf() throws {
        #expect(throws: ParolaError.self) { _ = try PdfExporter().renderText(sample()) }
    }

    @Test("srt with includeSpeakers prefixes each cue")
    func srtSpeakers() throws {
        let exporter = SrtExporter(options: SubtitleOptions(includeSpeakers: true))
        let out = try exporter.renderText(sampleWithSpeakers())
        #expect(out.contains("Speaker 1: Hello world."))
        #expect(out.contains("Speaker 2: This is Parola."))
    }

    @Test("srt without includeSpeakers omits them by default")
    func srtNoSpeakersDefault() throws {
        let out = try SrtExporter().renderText(sampleWithSpeakers())
        #expect(out.contains("Speaker 1:") == false)
        #expect(out.contains("Hello world."))
    }

    @Test("vtt with includeSpeakers wraps cues in <v> tags")
    func vttSpeakers() throws {
        let exporter = VttExporter(options: SubtitleOptions(includeSpeakers: true))
        let out = try exporter.renderText(sampleWithSpeakers())
        #expect(out.contains("<v Speaker 1>Hello world.</v>"))
        #expect(out.contains("<v Speaker 2>This is Parola.</v>"))
    }

    @Test("vtt without includeSpeakers omits them by default")
    func vttNoSpeakersDefault() throws {
        let out = try VttExporter().renderText(sampleWithSpeakers())
        #expect(out.contains("<v") == false)
    }

    @Test("vtt escapes markup in body and speaker but keeps apostrophes literal")
    func vttEscapesMarkupNotApostrophes() throws {
        let transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1.5, text: "a < b & c > d, don't <i>x</i>", speaker: "Ann <Boss> & Co"),
            ],
            language: "en",
            modelName: "m",
            sourceURL: URL(fileURLWithPath: "/tmp/x.wav"),
            durationSeconds: 1.5
        )
        let out = try VttExporter(options: SubtitleOptions(includeSpeakers: true)).renderText(transcript)
        #expect(out.contains("a &lt; b &amp; c &gt; d"))
        #expect(out.contains("&lt;i&gt;x&lt;/i&gt;"))
        #expect(out.contains("<v Ann &lt;Boss&gt; &amp; Co>"))
        // WebVTT players do not decode numeric refs, so apostrophes/quotes must stay literal.
        #expect(out.contains("don't"))
        #expect(out.contains("&#39;") == false)
        #expect(out.contains("&quot;") == false)
    }

    @Test("decimalSeconds avoids scientific notation and trims trailing zeros")
    func decimalSecondsFormatting() {
        #expect(Format.decimalSeconds(0.00001) == "0.00001")
        #expect(Format.decimalSeconds(1.5) == "1.5")
        #expect(Format.decimalSeconds(0.0) == "0.0")
        #expect(Format.decimalSeconds(4.0) == "4.0")
        #expect(Format.decimalSeconds(7.25) == "7.25")
        #expect(Format.decimalSeconds(0.00001).contains("e") == false)
    }

    @Test("csv renders a sub-millisecond start without an exponent")
    func csvSmallTimestampNoExponent() throws {
        let transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0.00001, end: 1.5, text: "hi")],
            language: "en",
            modelName: "tiny"
        )
        let csv = try CsvExporter().renderText(transcript)
        #expect(csv.contains("0.00001,1.5,"))
        #expect(csv.contains("1e-05") == false)
    }

    @Test("tsv emits header and tab-separated rows")
    func tsvHeader() throws {
        let out = try TsvExporter().renderText(sample())
        #expect(out.hasPrefix("start_seconds\tend_seconds\tspeaker\ttext\n"))
        #expect(out.contains("0.0\t1.5\t\tHello world."))
    }

    @Test("tsv escapes tabs and newlines in fields")
    func tsvEscape() throws {
        let transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: "tab\there"),
                TranscriptSegment(id: 1, start: 1, end: 2, text: "line1\nline2"),
            ],
            language: "en",
            modelName: "x"
        )
        let out = try TsvExporter().renderText(transcript)
        #expect(out.contains("tab\\there"))
        #expect(out.contains("line1\\nline2"))
        #expect(out.contains("tab\there") == false)
    }

    @Test("tsv is a recognized ExportFormat")
    func tsvFormat() {
        #expect(ExportFormat.tsv.fileExtension == "tsv")
        #expect(Exporters.exporter(for: .tsv) is TsvExporter)
    }

    @Test("Format namespace provides shared helpers")
    func formatNamespace() {
        #expect(Format.timestampHHMMSS(0) == "00:00:00")
        #expect(Format.timestampHHMMSS(3661) == "01:01:01")
        #expect(Format.escapeHTML("a < b & c") == "a &lt; b &amp; c")
        #expect(Format.escapeXML("<x>") == "&lt;x&gt;")
    }

    @Test("pdf with non-Latin language still produces glyphs (font cascade)")
    func pdfCJK() throws {
        let transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "你好，世界")],
            language: "zh",
            modelName: "x"
        )
        let data = try PdfExporter().render(transcript)
        let doc = try #require(PDFDocument(data: data))
        let text = (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined()
        #expect(text.contains("你好"))
    }

    @Test("ExportPreset round-trips through JSON")
    func exportPresetRoundTrip() throws {
        let preset = ExportPreset(
            name: "YouTube",
            formats: [.srt, .vtt, .pdf],
            markdownOptions: MarkdownOptions(showTimestamps: true),
            subtitleOptions: SubtitleOptions(includeSpeakers: true)
        )
        let encoded = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(ExportPreset.self, from: encoded)
        #expect(decoded == preset)
    }

    @Test("ExportPreset.exporter applies options for declared formats")
    func exportPresetExporter() throws {
        let preset = ExportPreset(
            name: "speakers",
            formats: [.srt],
            subtitleOptions: SubtitleOptions(includeSpeakers: true)
        )
        let exporter = try #require(preset.exporter(for: .srt))
        let out = try exporter.renderText(sampleWithSpeakers())
        #expect(out.contains("Speaker 1: Hello world."))
    }

    @Test("ExportPreset.exporter is nil for formats not in the preset")
    func exportPresetExcludes() {
        let preset = ExportPreset(name: "txt-only", formats: [.txt])
        #expect(preset.exporter(for: .srt) == nil)
        #expect(preset.exporter(for: .txt) is TxtExporter)
    }
}
