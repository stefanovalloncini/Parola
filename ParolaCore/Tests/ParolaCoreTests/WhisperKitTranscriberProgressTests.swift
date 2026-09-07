import Foundation
import Testing
@testable import ParolaCore
@preconcurrency import WhisperKit

@Suite("WhisperKitTranscriber progress")
struct WhisperKitTranscriberProgressTests {
    @Test("absolute position adds the chunk offset carried in seek to the chunk-local end")
    func chunkOffsetAccumulates() throws {
        let chunkOne = [TranscriptionSegment(seek: 0, start: 26.0, end: 28.6, text: "one")]
        let chunkTwoOffsetSamples = Int(29.5 * Double(WhisperKit.sampleRate))
        let chunkTwo = [TranscriptionSegment(seek: chunkTwoOffsetSamples, start: 1.0, end: 2.9, text: "two")]

        let positionOne = try #require(WhisperKitTranscriber.absolutePosition(for: chunkOne))
        let positionTwo = try #require(WhisperKitTranscriber.absolutePosition(for: chunkTwo))

        #expect(abs(positionOne - 28.6) < 0.001)
        #expect(abs(positionTwo - 32.4) < 0.001)
        #expect(positionTwo > positionOne, "the second chunk's position must include its own chunk offset, not just its chunk-local end")
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
