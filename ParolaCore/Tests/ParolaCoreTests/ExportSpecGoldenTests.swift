import Foundation
import PDFKit
import Testing
@testable import ParolaCore

@Suite("Export goldens", .tags(.fileSystem))
struct ExportSpecGoldenTests {

    static func fixture() -> Transcript {
        Transcript(
            segments: [
                TranscriptSegment(
                    id: 0,
                    start: 0,
                    end: 3.5,
                    text: "Welcome back to the show.",
                    speaker: "Ada",
                    words: [
                        WordTiming(id: "0-0", word: "Welcome", start: 0, end: 0.6, probability: 0.98),
                        WordTiming(id: "0-1", word: "back", start: 0.6, end: 0.9, probability: 0.97),
                        WordTiming(id: "0-2", word: "to", start: 0.9, end: 1.1, probability: 0.99),
                        WordTiming(id: "0-3", word: "the", start: 1.1, end: 1.3, probability: 0.95),
                        WordTiming(id: "0-4", word: "show.", start: 1.3, end: 3.5, probability: 0.92),
                    ]
                ),
                TranscriptSegment(
                    id: 1,
                    start: 3.5,
                    end: 9.125,
                    text: "Glad to be here — we shipped the \"export\" rewrite & it works.",
                    speaker: "Grace"
                ),
                TranscriptSegment(id: 2, start: 9.125, end: 14, text: "Tell me how it went.", speaker: "Ada"),
            ],
            language: "en",
            modelName: "openai_whisper-tiny",
            sourceURL: URL(fileURLWithPath: "/tmp/parola-goldens/interview.m4a"),
            durationSeconds: 14
        )
    }

    /// Set PAROLA_REGENERATE_EXPORT_GOLDEN=1 to rewrite Tests/Resources/export-golden/.
    /// Inspect the diff before committing: these files pin the bytes every export produces.
    private func compare(_ format: ExportFormat) throws {
        let exporter = Exporters.exporter(for: ExportSpec.standard(for: format))
        let actual = try exporter.render(Self.fixture())
        let filename = "\(format.rawValue).\(format.fileExtension)"

        if ProcessInfo.processInfo.environment["PAROLA_REGENERATE_EXPORT_GOLDEN"] != nil {
            let dir = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/export-golden", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try actual.write(to: dir.appendingPathComponent(filename))
            Issue.record("Regenerated \(filename). Re-run without PAROLA_REGENERATE_EXPORT_GOLDEN.")
            return
        }

        let url = try #require(
            Bundle.module.url(forResource: filename, withExtension: nil, subdirectory: "export-golden"),
            "missing golden: \(filename). Re-run with PAROLA_REGENERATE_EXPORT_GOLDEN=1 to create it."
        )
        let expected = try Data(contentsOf: url)

        // A CGPDFContext stamps a creation date and a file ID, so only the text layer is stable.
        if format == .pdf {
            let actualText = try #require(PDFDocument(data: actual)?.string)
            let expectedText = try #require(PDFDocument(data: expected)?.string)
            #expect(actualText == expectedText)
            return
        }
        #expect(actual == expected, "\(filename): export output diverged from its golden file.")
    }

    @Test("every format reproduces its golden file", arguments: ExportFormat.allCases)
    func goldenMatches(_ format: ExportFormat) throws {
        try compare(format)
    }

    @Test("the fixture covers two speakers and word timings")
    func fixtureShape() {
        let transcript = Self.fixture()
        #expect(transcript.segments.count == 3)
        #expect(Set(transcript.segments.compactMap(\.speaker)) == ["Ada", "Grace"])
        #expect(transcript.segments.filter { $0.words?.isEmpty == false }.count == 1)
    }
}
