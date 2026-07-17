import Foundation
import Testing
@testable import ParolaCore

@Suite("Degenerate subtitle cues")
struct SubtitleDegenerateCueTests {
    private func makeTranscript() -> Transcript {
        Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 5, end: 5, text: "zero length"),
                TranscriptSegment(id: 1, start: 10, end: 9.5, text: "inverted"),
                TranscriptSegment(id: 2, start: 20, end: 21, text: "normal"),
            ],
            language: "en",
            modelName: "tiny"
        )
    }

    private func cueTimestampLines(in rendered: String) -> [(start: String, end: String)] {
        rendered.split(separator: "\n")
            .filter { $0.contains("-->") }
            .map { line in
                let parts = line.components(separatedBy: " --> ")
                return (String(parts[0]), String(parts[1]))
            }
    }

    @Test("SRT export floors zero-length and inverted cues to a displayable duration")
    func srtFloorsDegenerateCues() throws {
        let data = try SrtExporter().render(makeTranscript())
        let rendered = String(decoding: data, as: UTF8.self)
        let cues = cueTimestampLines(in: rendered)
        #expect(cues.count == 3)
        for cue in cues {
            #expect(cue.start < cue.end, "cue \(cue.start) --> \(cue.end) would never display")
        }
    }

    @Test("VTT export floors zero-length and inverted cues to a displayable duration")
    func vttFloorsDegenerateCues() throws {
        let data = try VttExporter().render(makeTranscript())
        let rendered = String(decoding: data, as: UTF8.self)
        let cues = cueTimestampLines(in: rendered)
        #expect(cues.count == 3)
        for cue in cues {
            #expect(cue.start < cue.end, "cue \(cue.start) --> \(cue.end) would never display")
        }
    }
}
