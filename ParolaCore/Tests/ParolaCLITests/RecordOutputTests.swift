import Foundation
import Testing
import ParolaCore
@testable import parola

@Suite("parola record output")
struct RecordOutputTests {
    @Test("a finished take is written with the Italian orthography fixed")
    func emitAppliesOrthography() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-record-\(UUID().uuidString).txt").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let record = try Record.parse(["--format", "txt", "--output", path])
        let take = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: "Non so perchè."),
                TranscriptSegment(id: 1, start: 1, end: 2, text: "Un pò di più."),
            ],
            language: "it",
            modelName: "openai_whisper-tiny"
        )

        try record.emit(take)

        let written = try String(contentsOfFile: path, encoding: .utf8)
        #expect(written.contains("Non so perché."))
        #expect(written.contains("Un po' di più."))
        #expect(!written.contains("perchè"))
    }
}
