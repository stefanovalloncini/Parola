import Foundation
import Testing
import os
@testable import ParolaCore

private func rotated(degrees: Double) -> [Float] {
    let radians = degrees * .pi / 180
    return [Float(cos(radians)), Float(sin(radians))]
}

@Suite("Speaker centroid tracker")
struct SpeakerCentroidTrackerTests {
    @Test("repeated embeddings of one voice keep one label")
    func sameSpeakerKeepsLabel() {
        var tracker = SpeakerCentroidTracker()
        #expect(tracker.label(for: [1, 0, 0]) == "Speaker 1")
        #expect(tracker.label(for: [0.9, 0.1, 0]) == "Speaker 1")
        #expect(tracker.label(for: [1, 0.05, 0]) == "Speaker 1")
    }

    @Test("distant embeddings open new speakers, and each voice keeps its own label")
    func distinctSpeakersGetDistinctLabels() {
        var tracker = SpeakerCentroidTracker()
        #expect(tracker.label(for: [1, 0, 0]) == "Speaker 1")
        #expect(tracker.label(for: [0, 1, 0]) == "Speaker 2")
        #expect(tracker.label(for: [0, 0, 1]) == "Speaker 3")
        #expect(tracker.label(for: [0.95, 0.05, 0]) == "Speaker 1")
        #expect(tracker.label(for: [0, 0.05, 0.95]) == "Speaker 3")
    }

    @Test("a distance exactly at the threshold still matches")
    func exactThresholdMatches() {
        var tracker = SpeakerCentroidTracker(maxAssignmentDistance: 1.0)
        #expect(tracker.label(for: [1, 0]) == "Speaker 1")
        #expect(tracker.label(for: [0, 1]) == "Speaker 1")
    }

    @Test("a distance just past the threshold opens a new speaker")
    func pastThresholdOpensNewSpeaker() {
        var tracker = SpeakerCentroidTracker(maxAssignmentDistance: 0.3)
        #expect(tracker.label(for: [1, 0]) == "Speaker 1")
        #expect(tracker.label(for: [1, 1]) == "Speaker 1")
        var strict = SpeakerCentroidTracker(maxAssignmentDistance: 0.29)
        #expect(strict.label(for: [1, 0]) == "Speaker 1")
        #expect(strict.label(for: [1, 1]) == "Speaker 2")
    }

    @Test("the running-mean centroid follows a drifting voice")
    func centroidFollowsDrift() {
        var tracker = SpeakerCentroidTracker(maxAssignmentDistance: 0.05)
        for degrees in stride(from: 0.0, through: 30.0, by: 6.0) {
            #expect(tracker.label(for: rotated(degrees: degrees)) == "Speaker 1")
        }
        var fresh = SpeakerCentroidTracker(maxAssignmentDistance: 0.05)
        #expect(fresh.label(for: rotated(degrees: 0)) == "Speaker 1")
        #expect(fresh.label(for: rotated(degrees: 30)) == "Speaker 2")
    }

    @Test("degenerate embeddings produce no label and no speaker")
    func degenerateEmbeddingsRejected() {
        var tracker = SpeakerCentroidTracker()
        #expect(tracker.label(for: []) == nil)
        #expect(tracker.label(for: [0, 0, 0]) == nil)
        #expect(tracker.label(for: [Float.nan, 1]) == nil)
        #expect(tracker.label(for: [1, 0]) == "Speaker 1")
    }

    @Test("cosine distance handles orthogonal, identical, and mismatched inputs")
    func cosineDistanceBasics() {
        #expect(SpeakerCentroidTracker.cosineDistance([1, 0], [0, 1]) == 1)
        #expect(SpeakerCentroidTracker.cosineDistance([1, 0], [2, 0]) == 0)
        #expect(SpeakerCentroidTracker.cosineDistance([1, 0], [1, 0, 0]) == nil)
        #expect(SpeakerCentroidTracker.cosineDistance([0, 0], [1, 0]) == nil)
    }
}

private final class EmbeddingScript: Sendable {
    private let state: OSAllocatedUnfairLock<(queued: [[Float]], windows: [[Float]])>

    init(_ embeddings: [[Float]]) {
        state = OSAllocatedUnfairLock(initialState: (embeddings, []))
    }

    func next(for window: [Float]) throws -> [Float] {
        try state.withLock { state in
            state.windows.append(window)
            guard !state.queued.isEmpty else { throw ParolaError.transcriptionFailed("script exhausted") }
            return state.queued.removeFirst()
        }
    }

    var windows: [[Float]] { state.withLock { $0.windows } }
}

private func makeSegment(start: Double = 0, end: Double = 2) -> TranscriptSegment {
    TranscriptSegment(id: 0, start: start, end: end, text: "hi")
}

@Suite("Incremental speaker labeler")
struct IncrementalSpeakerLabelerTests {
    @Test("labels come from matching scripted embeddings across calls")
    func labelsFollowEmbeddings() async {
        let script = EmbeddingScript([[1, 0], [0, 1], [0.95, 0.05]])
        let labeler = IncrementalSpeakerLabeler { try script.next(for: $0) }
        let window = [Float](repeating: 0.1, count: 16_000)
        #expect(await labeler.labelSpeaker(for: makeSegment(), audioWindow: window, windowStartTime: 0, sampleRate: 16_000) == "Speaker 1")
        #expect(await labeler.labelSpeaker(for: makeSegment(), audioWindow: window, windowStartTime: 0, sampleRate: 16_000) == "Speaker 2")
        #expect(await labeler.labelSpeaker(for: makeSegment(), audioWindow: window, windowStartTime: 0, sampleRate: 16_000) == "Speaker 1")
    }

    @Test("an unexpected sample rate skips embedding entirely")
    func wrongSampleRateSkips() async {
        let script = EmbeddingScript([[1, 0]])
        let labeler = IncrementalSpeakerLabeler { try script.next(for: $0) }
        let window = [Float](repeating: 0.1, count: 16_000)
        let label = await labeler.labelSpeaker(for: makeSegment(), audioWindow: window, windowStartTime: 0, sampleRate: 44_100)
        #expect(label == nil)
        #expect(script.windows.isEmpty)
    }

    @Test("windows shorter than the minimum are skipped")
    func shortWindowSkips() async {
        let script = EmbeddingScript([[1, 0]])
        let labeler = IncrementalSpeakerLabeler { try script.next(for: $0) }
        let window = [Float](repeating: 0.1, count: 4_000)
        let label = await labeler.labelSpeaker(for: makeSegment(), audioWindow: window, windowStartTime: 0, sampleRate: 16_000)
        #expect(label == nil)
        #expect(script.windows.isEmpty)
    }

    @Test("oversized windows are capped to the extractor's 10-second buffer")
    func oversizedWindowCapped() async {
        let script = EmbeddingScript([[1, 0]])
        let labeler = IncrementalSpeakerLabeler { try script.next(for: $0) }
        let window = [Float](repeating: 0.1, count: 200_000)
        let label = await labeler.labelSpeaker(for: makeSegment(), audioWindow: window, windowStartTime: 0, sampleRate: 16_000)
        #expect(label == "Speaker 1")
        #expect(script.windows.first?.count == 160_000)
    }

    @Test("an embedding failure leaves the segment unlabeled")
    func embeddingFailureLeavesNil() async {
        let script = EmbeddingScript([])
        let labeler = IncrementalSpeakerLabeler { try script.next(for: $0) }
        let window = [Float](repeating: 0.1, count: 16_000)
        let label = await labeler.labelSpeaker(for: makeSegment(), audioWindow: window, windowStartTime: 0, sampleRate: 16_000)
        #expect(label == nil)
    }

    @Test("modelsInstalled is false for an empty store and the directory ends with the FluidAudio folder name")
    func modelsInstalledChecksStoreDirectory() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("labeler-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = ModelStore(modelsDirectory: tmp)
        #expect(IncrementalSpeakerLabeler.modelsInstalled(store: store) == false)

        let dir = IncrementalSpeakerLabeler.modelsDirectory(store: store)
        #expect(dir.path.hasPrefix(tmp.path))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["pyannote_segmentation.mlmodelc", "wespeaker_v2.mlmodelc"] {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        #expect(IncrementalSpeakerLabeler.modelsInstalled(store: store))
    }
}
