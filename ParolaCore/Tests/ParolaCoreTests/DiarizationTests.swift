import Foundation
import Testing
@preconcurrency import SpeakerKit
@testable import ParolaCore

@Suite("Diarization merge")
struct DiarizationTests {
    private func speakerSegment(_ id: Int, _ start: Float, _ end: Float) -> SpeakerSegment {
        SpeakerSegment(
            speaker: .speakerId(id),
            startTime: start,
            endTime: end,
            frameRate: 100
        )
    }

    private func diarization(_ segments: [SpeakerSegment]) -> DiarizationResult {
        DiarizationResult(
            speakerCount: 2,
            totalFrames: 10_000,
            frameRate: 100,
            segments: segments
        )
    }

    private func word(_ idx: Int, _ start: Double, _ end: Double, _ text: String) -> WordTiming {
        WordTiming(
            id: "0-\(idx)",
            word: text,
            start: start,
            end: end,
            probability: 1.0
        )
    }

    @Test("a segment with no words gets the dominant speaker by overlap")
    func segmentWithoutWordsGetsDominantSpeaker() {
        let seg = TranscriptSegment(id: 0, start: 0, end: 5, text: "hi there")
        let transcript = Transcript(segments: [seg], language: "en", modelName: "tiny")
        let result = diarization([
            speakerSegment(0, 0, 4),
            speakerSegment(1, 4, 5)
        ])
        let merged = DiarizationService.merge(transcript: transcript, diarization: result)
        #expect(merged.segments.count == 1)
        #expect(merged.segments[0].speaker == "Speaker 1")
    }

    @Test("words inside a single speaker run stay in one segment")
    func singleSpeakerKeepsOneSegment() {
        let words = [
            word(0, 0, 1, "hello"),
            word(1, 1, 2, "world")
        ]
        let seg = TranscriptSegment(id: 0, start: 0, end: 2, text: "hello world", words: words)
        let transcript = Transcript(segments: [seg], language: "en", modelName: "tiny")
        let result = diarization([
            speakerSegment(0, 0, 2)
        ])
        let merged = DiarizationService.merge(transcript: transcript, diarization: result)
        #expect(merged.segments.count == 1)
        #expect(merged.segments[0].speaker == "Speaker 1")
        #expect(merged.segments[0].words?.allSatisfy { $0.speaker == "Speaker 1" } == true)
    }

    @Test("speaker change inside a segment splits it on the boundary")
    func speakerChangeSplitsSegment() {
        let words = [
            word(0, 0, 1, "hi"),
            word(1, 1, 2, "there"),
            word(2, 2, 3, "ok"),
            word(3, 3, 4, "sure")
        ]
        let seg = TranscriptSegment(id: 10, start: 0, end: 4, text: "hi there ok sure", words: words)
        let transcript = Transcript(segments: [seg], language: "en", modelName: "tiny")
        let result = diarization([
            speakerSegment(0, 0, 2),
            speakerSegment(1, 2, 4)
        ])
        let merged = DiarizationService.merge(transcript: transcript, diarization: result)
        #expect(merged.segments.count == 2)
        #expect(merged.segments[0].speaker == "Speaker 1")
        #expect(merged.segments[1].speaker == "Speaker 2")
        #expect(merged.segments[0].id == 10)
        #expect(merged.segments[1].id != 10)
        #expect(merged.segments[0].words?.count == 2)
        #expect(merged.segments[1].words?.count == 2)
    }

    @Test("words inherit their per-word speaker when present")
    func wordsCarrySpeakerLabel() {
        let words = [
            word(0, 0, 1, "ciao"),
            word(1, 1, 2, "tutti")
        ]
        let seg = TranscriptSegment(id: 0, start: 0, end: 2, text: "ciao tutti", words: words)
        let transcript = Transcript(segments: [seg], language: "it", modelName: "tiny")
        let result = diarization([speakerSegment(2, 0, 2)])
        let merged = DiarizationService.merge(transcript: transcript, diarization: result)
        let firstWord = try? #require(merged.segments.first?.words?.first)
        #expect(firstWord?.speaker == "Speaker 3")
    }
}
