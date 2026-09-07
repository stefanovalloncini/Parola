import Foundation
import Testing
@testable import ParolaCore
@preconcurrency import WhisperKit

@Suite("WhisperKitTranscriber progress")
struct WhisperKitTranscriberProgressTests {
    @Test("a single-window chunk's position is chunk offset plus the segment end")
    func singleWindowChunkPosition() throws {
        let sr = Double(WhisperKit.sampleRate)
        let chunkOffsetSamples = Int(30.0 * sr)
        // Window 1 of a chunk always has local seek 0, so `start` on the earliest segment is the
        // within-window offset directly — here 0, i.e. speech starts right at the chunk boundary.
        let segments = [TranscriptionSegment(seek: chunkOffsetSamples, start: 0, end: 25.0, text: "one")]

        let position = try #require(WhisperKitTranscriber.absolutePosition(for: segments))
        #expect(abs(position - 55.0) < 0.001) // chunk offset 30 + end 25
    }

    @Test("a chunk that decodes across two windows is not double counted")
    func twoWindowChunkDoesNotDoubleCount() throws {
        let sr = Double(WhisperKit.sampleRate)
        let chunkOffsetSamples = Int(30.0 * sr)

        // Window 1 of the chunk: local seek 0.
        let windowOne = [TranscriptionSegment(seek: chunkOffsetSamples, start: 0, end: 25.0, text: "one")]

        // Window 2 of the SAME chunk: WhisperKit's local seek for this window is 25.0s of samples
        // (TranscribeTask decodes past the first window without exhausting the chunk). The outer
        // `.vad` adjustment adds the chunk offset on top of that local seek (WhisperKit.swift:754-763,
        // `adjustedSegments[i].seek += seekOffset`), while `start`/`end` (SegmentSeeker.swift:126-127,
        // built from `timeOffset = seek / sampleRate` of that same window) already carry the 25.0s
        // window offset — so naively adding `seek/sr + end` counts it twice.
        let windowTwoLocalSeekSamples = Int(25.0 * sr)
        let windowTwo = [TranscriptionSegment(
            seek: chunkOffsetSamples + windowTwoLocalSeekSamples, start: 25.0, end: 28.5, text: "two"
        )]

        let positionOne = try #require(WhisperKitTranscriber.absolutePosition(for: windowOne))
        let positionTwo = try #require(WhisperKitTranscriber.absolutePosition(for: windowTwo))

        #expect(abs(positionOne - 55.0) < 0.001) // chunk offset 30 + window-1 end 25
        // chunk offset 30 + window-2 end 28.5 = 58.5. The old `seek/sr + end` arithmetic gave
        // 55.0 (seek/sr) + 28.5 (end) = 83.5 here — 25s past the true position.
        #expect(abs(positionTwo - 58.5) < 0.001)
        #expect(positionTwo < 83.5, "must not reproduce the old double-counted value")
    }

    @Test("progress is monotonic across chunks and reaches 0.95 before completion")
    func multiChunkProgressReachesNearCompletion() throws {
        let duration = 90.0
        let chunkLength = 29.5
        let chunkOffsets = stride(from: 0.0, to: duration, by: chunkLength).map { $0 }

        var lastFraction = 0.0
        for offset in chunkOffsets {
            let seek = Int(offset * Double(WhisperKit.sampleRate))
            let localEnd = Float(min(chunkLength - 0.5, duration - offset - 0.1))
            let segments = [TranscriptionSegment(seek: seek, start: 0, end: localEnd, text: "chunk")]

            let position = try #require(WhisperKitTranscriber.absolutePosition(for: segments))
            let fraction = min(1, max(lastFraction, position / duration))
            #expect(fraction >= lastFraction)
            lastFraction = fraction
        }

        #expect(lastFraction >= 0.95)
    }
}
