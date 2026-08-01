import Foundation
import Testing
@preconcurrency import SpeakerKit
@testable import ParolaCore

@Suite("Diarization speaker matching")
struct DiarizationMatchTests {
    @Test("overlap matching picks the most-overlapping interval")
    func overlapMatching() {
        let ivs = [(start: 0.0, end: 2.0), (start: 2.0, end: 5.0)]
        #expect(DiarizationService.bestMatchIndex(start: 0.5, end: 1.5, intervals: ivs) == 0)
        #expect(DiarizationService.bestMatchIndex(start: 3.0, end: 4.0, intervals: ivs) == 1)
        #expect(DiarizationService.bestMatchIndex(start: 9.0, end: 10.0, intervals: ivs) == nil)
    }

    @Test("a zero-duration word is matched by containment, not overlap")
    func zeroDurationContainment() {
        let ivs = [(start: 0.0, end: 4.0)]
        #expect(DiarizationService.bestMatchIndex(start: 2.0, end: 2.0, intervals: ivs) == 0)
        #expect(DiarizationService.bestMatchIndex(start: 0.0, end: 0.0, intervals: ivs) == 0)
        #expect(DiarizationService.bestMatchIndex(start: 5.0, end: 5.0, intervals: ivs) == nil)
    }

    private func speakerSegments(_ intervals: [(start: Double, end: Double)]) -> [SpeakerSegment] {
        intervals.enumerated().map { index, interval in
            SpeakerSegment(
                speaker: .speakerId(index % 4),
                startTime: Float(interval.start),
                endTime: Float(interval.end),
                frameRate: 100
            )
        }
    }

    private func awkwardIntervals(count: Int, rng: inout SplitMix64) -> [(start: Double, end: Double)] {
        var intervals: [(start: Double, end: Double)] = []
        var cursor = 0.0
        while intervals.count < count {
            let length = Double(Int.random(in: 0...60, using: &rng)) / 10
            intervals.append((start: cursor, end: cursor + length))
            switch Int.random(in: 0..<4, using: &rng) {
            case 0:
                intervals.append((start: cursor, end: cursor + length / 2))
            case 1:
                intervals.append((start: cursor + length / 2, end: cursor + length * 2))
            case 2:
                cursor += length + Double(Int.random(in: 1...20, using: &rng)) / 10
            default:
                cursor += length
            }
        }
        return intervals
            .map { (start: Double(Float($0.start)), end: Double(Float($0.end))) }
            .sorted { $0.start < $1.start }
    }

    private func queries(over intervals: [(start: Double, end: Double)], count: Int, rng: inout SplitMix64) -> [(start: Double, end: Double)] {
        let span = (intervals.last?.end ?? 1) + 2
        var out: [(start: Double, end: Double)] = []
        for i in 0..<count {
            let edge = intervals[i % intervals.count]
            switch i % 5 {
            case 0:
                out.append((start: edge.start, end: edge.end))
            case 1:
                out.append((start: edge.end, end: edge.end))
            case 2:
                out.append((start: edge.start, end: edge.start))
            case 3:
                let start = Double(Int.random(in: 0...Int(span * 10), using: &rng)) / 10
                out.append((start: start, end: start + Double(Int.random(in: 0...12, using: &rng)) / 10))
            default:
                out.append((start: edge.start - 0.05, end: edge.end + 0.05))
            }
        }
        return out
    }

    @Test("prepared intervals match the linear scan on overlapping, gapped and boundary cases")
    func preparedIntervalsMatchLinearScan() {
        var rng = SplitMix64(seed: 0xD1A21A)
        let intervals = awkwardIntervals(count: 600, rng: &rng)
        let prepared = DiarizationService.SpeakerIntervals(speakerSegments(intervals))
        var mismatches: [(start: Double, end: Double)] = []
        for query in queries(over: intervals, count: 10_000, rng: &rng) {
            let fast = prepared.matchIndex(start: query.start, end: query.end)
            let reference = DiarizationService.bestMatchIndex(start: query.start, end: query.end, intervals: intervals)
            if fast != reference { mismatches.append(query) }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) lookups disagreed, first \(String(describing: mismatches.first))")
    }

    @Test("out-of-order intervals fall back to the linear scan")
    func unsortedIntervalsMatchLinearScan() {
        var rng = SplitMix64(seed: 0x5CA77E)
        let intervals = awkwardIntervals(count: 120, rng: &rng).shuffled(using: &rng)
        let prepared = DiarizationService.SpeakerIntervals(speakerSegments(intervals))
        for query in queries(over: intervals, count: 2_000, rng: &rng) {
            let reference = DiarizationService.bestMatchIndex(start: query.start, end: query.end, intervals: intervals)
            #expect(prepared.matchIndex(start: query.start, end: query.end) == reference)
        }
    }

    @Test("merging a word-timestamped hour labels every word like the linear scan")
    func mergeMatchesLinearScanOnLongTranscript() throws {
        var rng = SplitMix64(seed: 0xB16B00)
        let intervals = awkwardIntervals(count: 400, rng: &rng)
        let speakers = speakerSegments(intervals)
        let span = intervals.last?.end ?? 1

        var words: [WordTiming] = []
        var time = 0.0
        for i in 0..<10_000 {
            let length = i % 7 == 0 ? 0 : Double(Int.random(in: 1...6, using: &rng)) / 100
            words.append(WordTiming(id: "w\(i)", word: "w\(i)", start: time, end: time + length, probability: 1))
            time += length + Double(Int.random(in: 0...4, using: &rng)) / 100
            if time > span { time = 0 }
        }
        let segments = stride(from: 0, to: words.count, by: 25).map { offset -> TranscriptSegment in
            let slice = Array(words[offset..<min(offset + 25, words.count)])
            return TranscriptSegment(
                id: offset / 25,
                start: slice[0].start,
                end: slice[slice.count - 1].end,
                text: slice.map(\.word).joined(separator: " "),
                words: slice
            )
        }
        let transcript = Transcript(segments: segments, language: "en", modelName: "tiny")
        let result = DiarizationResult(speakerCount: 4, totalFrames: 100, frameRate: 100, segments: speakers)

        let merged = DiarizationService.merge(transcript: transcript, diarization: result)
        let mergedWords = merged.segments.flatMap { $0.words ?? [] }
        #expect(mergedWords.count == words.count)
        for (merged, original) in zip(mergedWords, words) {
            let index = DiarizationService.bestMatchIndex(start: original.start, end: original.end, intervals: intervals)
            let expected = index.map { "Speaker \((speakers[$0].speaker.speakerId ?? -1) + 1)" }
            #expect(merged.speaker == expected)
        }
    }
}
