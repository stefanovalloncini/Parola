import Foundation
import Testing
@testable import ParolaCore

@Suite("JSON Lines exporter")
struct JsonLinesExporterTests {
    @Test("emits one JSON object per line")
    func oneObjectPerLine() throws {
        let segments = [
            TranscriptSegment(id: 1, start: 0, end: 1, text: "hello"),
            TranscriptSegment(id: 2, start: 1, end: 2, text: "world"),
        ]
        let transcript = Transcript(
            schemaVersion: Transcript.currentSchemaVersion,
            segments: segments,
            language: "en",
            modelName: "tiny"
        )
        let data = try JsonLinesExporter().render(transcript)
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 2)
        for line in lines {
            let payload = Data(String(line).utf8)
            let segment = try JSONDecoder().decode(TranscriptSegment.self, from: payload)
            #expect([1, 2].contains(segment.id))
        }
    }

    @Test("empty transcript yields empty data")
    func empty() throws {
        let transcript = Transcript(
            schemaVersion: Transcript.currentSchemaVersion,
            segments: [],
            language: "en",
            modelName: "tiny"
        )
        let data = try JsonLinesExporter().render(transcript)
        #expect(data.isEmpty)
    }

    @Test("registered in Exporters")
    func registered() {
        let exporter = Exporters.exporter(for: .jsonl)
        #expect(exporter.format == .jsonl)
    }
}
