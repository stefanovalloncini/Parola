import Foundation
import Testing
@testable import ParolaCore

@Suite("Exporter snapshots", .tags(.fileSystem))
struct ExporterSnapshotTests {
    private func sample() -> Transcript {
        Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0.0, end: 1.5, text: "Hello world."),
                TranscriptSegment(id: 1, start: 1.5, end: 4.0, text: " This is Parola."),
                TranscriptSegment(id: 2, start: 4.0, end: 7.25, text: " Goodbye."),
            ],
            language: "en",
            modelName: "openai_whisper-tiny",
            durationSeconds: 7.25
        )
    }

    /// Set PAROLA_REGENERATE_SNAPSHOTS=1 to overwrite the committed expected
    /// files in Tests/Resources/expected/. Inspect the diff before committing.
    private func compare(format: ExportFormat, filename: String) throws {
        let exporter = Exporters.exporter(for: format)
        let actual = try exporter.renderText(sample())

        if ProcessInfo.processInfo.environment["PAROLA_REGENERATE_SNAPSHOTS"] != nil {
            let here = URL(fileURLWithPath: #filePath)
            let dir = here.deletingLastPathComponent().appendingPathComponent("Resources/expected", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let out = dir.appendingPathComponent(filename)
            try Data(actual.utf8).write(to: out)
            Issue.record("Regenerated \(filename) at \(out.path). Re-run tests without the env var.")
            return
        }

        let url = try #require(
            Bundle.module.url(forResource: filename, withExtension: nil, subdirectory: "expected"),
            "missing fixture: \(filename). Re-run with PAROLA_REGENERATE_SNAPSHOTS=1 to create it."
        )
        let expected = try String(contentsOf: url, encoding: .utf8)
        if actual != expected {
            Issue.record("""
            \(filename): exporter output diverged from snapshot.
            To accept the change: PAROLA_REGENERATE_SNAPSHOTS=1 swift test --filter ExporterSnapshotTests
            Then inspect the diff and commit.
            """)
        }
        #expect(actual == expected)
    }

    @Test("txt matches expected/snapshot.txt")
    func txt() throws { try compare(format: .txt, filename: "snapshot.txt") }

    @Test("srt matches expected/snapshot.srt")
    func srt() throws { try compare(format: .srt, filename: "snapshot.srt") }

    @Test("vtt matches expected/snapshot.vtt")
    func vtt() throws { try compare(format: .vtt, filename: "snapshot.vtt") }

    @Test("md matches expected/snapshot.md")
    func markdown() throws { try compare(format: .md, filename: "snapshot.md") }

    @Test("csv matches expected/snapshot.csv")
    func csv() throws { try compare(format: .csv, filename: "snapshot.csv") }

    @Test("html matches expected/snapshot.html")
    func html() throws { try compare(format: .html, filename: "snapshot.html") }
}
