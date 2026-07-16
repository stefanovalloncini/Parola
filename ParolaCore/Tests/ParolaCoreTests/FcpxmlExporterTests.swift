import Foundation
import Testing
@testable import ParolaCore

@Suite("FCPXML exporter")
struct FcpxmlExporterTests {
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

    private func parse(_ transcript: Transcript) throws -> XMLDocument {
        let data = try FcpxmlExporter().render(transcript)
        return try XMLDocument(data: data)
    }

    @Test("document parses as XML with an fcpxml 1.9 root")
    func rootAndVersion() throws {
        let doc = try parse(sample())
        let root = try #require(doc.rootElement())
        #expect(root.name == "fcpxml")
        #expect(root.attribute(forName: "version")?.stringValue == "1.9")
    }

    @Test("resources declare a 30fps format the sequence references")
    func formatResource() throws {
        let doc = try parse(sample())
        let format = try #require(try doc.nodes(forXPath: "//resources/format").first as? XMLElement)
        #expect(format.attribute(forName: "frameDuration")?.stringValue == "100/3000s")
        let sequence = try #require(try doc.nodes(forXPath: "//sequence").first as? XMLElement)
        #expect(sequence.attribute(forName: "format")?.stringValue == format.attribute(forName: "id")?.stringValue)
    }

    @Test("one caption per segment, on lane 1 of a gap spanning the transcript")
    func captionsOnGap() throws {
        let doc = try parse(sample())
        let gap = try #require(try doc.nodes(forXPath: "//spine/gap").first as? XMLElement)
        #expect(gap.attribute(forName: "duration")?.stringValue == "217500/30000s")
        let captions = try doc.nodes(forXPath: "//gap/caption")
        #expect(captions.count == 3)
        for caption in captions {
            #expect((caption as? XMLElement)?.attribute(forName: "lane")?.stringValue == "1")
        }
    }

    @Test("caption offsets and durations are rational 30000ths of the segment times")
    func rationalTimes() throws {
        let doc = try parse(sample())
        let second = try #require(try doc.nodes(forXPath: "//caption[2]").first as? XMLElement)
        #expect(second.attribute(forName: "offset")?.stringValue == "45000/30000s")
        #expect(second.attribute(forName: "duration")?.stringValue == "75000/30000s")
    }

    @Test("caption role carries an ITT captionFormat with the transcript language")
    func roleWithLanguage() throws {
        let italian = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "Ciao.")],
            language: "it",
            modelName: "x"
        )
        let doc = try parse(italian)
        let caption = try #require(try doc.nodes(forXPath: "//caption").first as? XMLElement)
        #expect(caption.attribute(forName: "role")?.stringValue == "iTT?captionFormat=ITT.it")
    }

    @Test("an unusable language falls back to en in the caption role")
    func roleLanguageFallback() throws {
        let unknown = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "Hi.")],
            language: "unknown",
            modelName: "x"
        )
        let doc = try parse(unknown)
        let caption = try #require(try doc.nodes(forXPath: "//caption").first as? XMLElement)
        #expect(caption.attribute(forName: "role")?.stringValue == "iTT?captionFormat=ITT.en")
    }

    @Test("caption text is escaped and round-trips through an XML parser")
    func textEscaped() throws {
        let tricky = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "a < b & \"c\"")],
            language: "en",
            modelName: "x"
        )
        let raw = try FcpxmlExporter().renderText(tricky)
        #expect(raw.contains("a &lt; b &amp; &quot;c&quot;"))
        let doc = try XMLDocument(data: utf8(raw))
        let style = try #require(try doc.nodes(forXPath: "//caption/text/text-style").first)
        #expect(style.stringValue == "a < b & \"c\"")
    }

    @Test("speaker labels are not written into caption text")
    func speakerOmitted() throws {
        let spoken = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello.", speaker: "Alice")],
            language: "en",
            modelName: "x"
        )
        let doc = try parse(spoken)
        let style = try #require(try doc.nodes(forXPath: "//caption/text/text-style").first)
        #expect(style.stringValue == "Hello.")
    }

    @Test("segments whose text trims to empty are dropped")
    func emptySegmentDropped() throws {
        let gappy = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello."),
                TranscriptSegment(id: 1, start: 1, end: 2, text: " \n "),
                TranscriptSegment(id: 2, start: 2, end: 3, text: "World."),
            ],
            language: "en",
            modelName: "x"
        )
        let doc = try parse(gappy)
        let captions = try doc.nodes(forXPath: "//caption")
        #expect(captions.count == 2)
    }

    @Test("each caption's text-style ref resolves to its own text-style-def")
    func styleRefsResolve() throws {
        let doc = try parse(sample())
        let refs = try doc.nodes(forXPath: "//caption/text/text-style/@ref").compactMap(\.stringValue)
        let ids = try doc.nodes(forXPath: "//caption/text-style-def/@id").compactMap(\.stringValue)
        #expect(refs.count == 3)
        #expect(refs == ids)
        #expect(Set(ids).count == ids.count)
    }

    @Test("gap duration falls back to the last segment end without a stored duration")
    func gapDurationFromSegments() throws {
        let bare = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 2.5, text: "Hi.")],
            language: "en",
            modelName: "x"
        )
        let doc = try parse(bare)
        let gap = try #require(try doc.nodes(forXPath: "//spine/gap").first as? XMLElement)
        #expect(gap.attribute(forName: "duration")?.stringValue == "75000/30000s")
    }

    @Test("a zero-duration segment still emits a caption of at least one frame")
    func zeroDurationCaptionSurvives() throws {
        let degenerate = Transcript(
            segments: [TranscriptSegment(id: 0, start: 5, end: 5, text: "Blip.")],
            language: "en",
            modelName: "x"
        )
        let doc = try parse(degenerate)
        let caption = try #require(try doc.nodes(forXPath: "//caption").first as? XMLElement)
        #expect(caption.attribute(forName: "duration")?.stringValue == "1000/30000s")
    }

    @Test("registered in Exporters with the fcpxml extension")
    func registration() {
        #expect(Exporters.exporter(for: .fcpxml).format == .fcpxml)
        #expect(ExportFormat.fcpxml.fileExtension == "fcpxml")
    }
}
