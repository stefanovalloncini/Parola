import Foundation
import Testing
@testable import ParolaCore

@Suite("Notes markdown renderer")
struct NotesMarkdownRendererTests {
    private func transcript(_ segments: [(Int, Double, String, String?)]) -> Transcript {
        Transcript(
            schemaVersion: 1,
            segments: segments.map {
                TranscriptSegment(id: $0.0, start: $0.1, end: $0.1 + 2, text: $0.2, speaker: $0.3)
            },
            language: "en",
            modelName: "x"
        )
    }

    @Test("emits one bullet per note, sorted by start time")
    func sortedBullets() {
        let t = transcript([
            (1, 0, "first segment", nil),
            (2, 30, "second segment", nil),
            (3, 60, "third segment", nil),
        ])
        let notes = ["3": "third note", "1": "first note"]
        let md = NotesMarkdownRenderer.render(transcript: t, notes: notes, title: "Review")
        let lines = md.split(separator: "\n").map(String.init)
        let bullets = lines.filter { $0.hasPrefix("- ") }
        #expect(bullets.count == 2)
        #expect(bullets[0].contains("00:00"))
        #expect(bullets[1].contains("01:00"))
    }

    @Test("includes the speaker when known")
    func includesSpeaker() {
        let t = transcript([(1, 0, "hello", "Alice")])
        let md = NotesMarkdownRenderer.render(transcript: t, notes: ["1": "important"], title: "x")
        #expect(md.contains("Alice"))
        #expect(md.contains("important"))
    }

    @Test("empty notes produce an empty body but keep the title")
    func emptyNotes() {
        let t = transcript([(1, 0, "hello", nil)])
        let md = NotesMarkdownRenderer.render(transcript: t, notes: [:], title: "Review")
        #expect(md.contains("Review"))
        let bullets = md.split(separator: "\n").filter { $0.hasPrefix("- ") }
        #expect(bullets.isEmpty)
    }

    @Test("ignores notes for unknown segment ids")
    func ignoresUnknown() {
        let t = transcript([(1, 0, "hello", nil)])
        let md = NotesMarkdownRenderer.render(transcript: t, notes: ["99": "stray"], title: "x")
        #expect(!md.contains("stray"))
    }
}
