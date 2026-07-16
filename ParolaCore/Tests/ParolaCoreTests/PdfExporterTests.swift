import Foundation
import PDFKit
import Testing
@testable import ParolaCore

@Suite("PDF exporter")
struct PdfExporterTests {
    private func render(_ segments: [TranscriptSegment]) throws -> Data {
        try PdfExporter().render(Transcript(segments: segments, language: "en", modelName: "x"))
    }

    private func text(of pdf: Data) -> String {
        PDFDocument(data: pdf)?.string ?? ""
    }

    @Test("emits a valid PDF whose text carries the segments")
    func rendersValidPdf() throws {
        let data = try render([
            TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello world."),
            TranscriptSegment(id: 1, start: 1, end: 2, text: "Goodbye."),
        ])
        #expect(data.starts(with: Data("%PDF".utf8)))
        let extracted = text(of: data)
        #expect(extracted.contains("Hello world."))
        #expect(extracted.contains("Goodbye."))
    }

    @Test("a whitespace-only speaker adds no label, like the other exporters")
    func whitespaceSpeakerRendersNoLabel() throws {
        let blank = text(of: try render([TranscriptSegment(id: 0, start: 0, end: 1, text: "Hi.", speaker: "   ")]))
        let labelled = text(of: try render([TranscriptSegment(id: 0, start: 0, end: 1, text: "Hi.", speaker: "Alice")]))
        #expect(labelled.contains("Alice:"))
        // The blank speaker must not draw a "  : " label.
        #expect(!blank.contains(":"))
        #expect(blank.contains("Hi."))
    }

    @Test("a speaker with a newline is flattened onto one label")
    func newlineSpeakerFlattened() throws {
        let data = try render([TranscriptSegment(id: 0, start: 0, end: 1, text: "Hi.", speaker: "Alice\nSmith")])
        #expect(data.starts(with: Data("%PDF".utf8)))
        let extracted = text(of: data)
        // Flattened to "Alice Smith", not split across lines mid-label.
        #expect(extracted.contains("Alice Smith:"))
    }
}
