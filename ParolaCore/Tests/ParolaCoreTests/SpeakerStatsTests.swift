import Foundation
import Testing
@testable import ParolaCore

@Suite("Speaker stats")
struct SpeakerStatsTests {
    private func segment(_ id: Int, start: Double, end: Double, text: String, speaker: String?) -> TranscriptSegment {
        TranscriptSegment(id: id, start: start, end: end, text: text, speaker: speaker)
    }

    private func transcript(_ segments: [TranscriptSegment]) -> Transcript {
        Transcript(schemaVersion: 1, segments: segments, language: "en", modelName: "x")
    }

    @Test("aggregates word, character, and duration per speaker")
    func aggregatesPerSpeaker() {
        let t = transcript([
            segment(1, start: 0, end: 3, text: "Hello there friend", speaker: "Alice"),
            segment(2, start: 3, end: 6, text: "Howdy", speaker: "Bob"),
            segment(3, start: 6, end: 9, text: "How are you", speaker: "Alice"),
        ])
        let stats = SpeakerStats.compute(for: t)
        let alice = stats.first { $0.speaker == "Alice" }
        let bob = stats.first { $0.speaker == "Bob" }
        #expect(alice?.wordCount == 6)
        #expect(alice?.characterCount == 29)
        #expect(alice?.durationSeconds == 6)
        #expect(bob?.wordCount == 1)
        #expect(bob?.durationSeconds == 3)
    }

    @Test("orders by first appearance")
    func orderedByFirstAppearance() {
        let t = transcript([
            segment(1, start: 0, end: 1, text: "x", speaker: "Bob"),
            segment(2, start: 1, end: 2, text: "y", speaker: "Alice"),
            segment(3, start: 2, end: 3, text: "z", speaker: "Bob"),
        ])
        let stats = SpeakerStats.compute(for: t)
        #expect(stats.map(\.speaker) == ["Bob", "Alice"])
    }

    @Test("ignores segments without speakers")
    func ignoresUnlabeled() {
        let t = transcript([
            segment(1, start: 0, end: 1, text: "x", speaker: nil),
            segment(2, start: 1, end: 2, text: "y", speaker: "Alice"),
        ])
        let stats = SpeakerStats.compute(for: t)
        #expect(stats.count == 1)
        #expect(stats[0].speaker == "Alice")
    }

    @Test("treats an empty-string speaker as unlabeled")
    func ignoresEmptyStringSpeaker() {
        let t = transcript([
            segment(1, start: 0, end: 4, text: "x", speaker: ""),
            segment(2, start: 4, end: 10, text: "y", speaker: "Alice"),
        ])
        let stats = SpeakerStats.compute(for: t)
        #expect(stats.count == 1)
        #expect(stats[0].speaker == "Alice")
        #expect(stats[0].share == 1)
    }

    @Test("share is the fraction of total duration")
    func share() {
        let t = transcript([
            segment(1, start: 0, end: 6, text: "x", speaker: "Alice"),
            segment(2, start: 6, end: 10, text: "y", speaker: "Bob"),
        ])
        let stats = SpeakerStats.compute(for: t)
        let alice = stats.first { $0.speaker == "Alice" }
        let bob = stats.first { $0.speaker == "Bob" }
        #expect(alice?.share == 0.6)
        #expect(bob?.share == 0.4)
    }

    @Test("empty transcript returns no stats")
    func emptyTranscript() {
        let t = transcript([])
        #expect(SpeakerStats.compute(for: t).isEmpty)
    }
}
