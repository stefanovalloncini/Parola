import Foundation
import Testing
import os
@preconcurrency import WhisperKit
@testable import ParolaCore

private final class RecordingLabeler: StreamingSpeakerLabeler {
    struct Call {
        var samples: [Float]
        var windowStartTime: TimeInterval
        var sampleRate: Double
    }

    private let state = OSAllocatedUnfairLock<[Call]>(initialState: [])
    private let result: String?

    init(result: String?) {
        self.result = result
    }

    func labelSpeaker(
        for segment: TranscriptSegment,
        audioWindow: ArraySlice<Float>,
        windowStartTime: TimeInterval,
        sampleRate: Double
    ) async -> String? {
        state.withLock {
            $0.append(Call(
                samples: Array(audioWindow),
                windowStartTime: windowStartTime,
                sampleRate: sampleRate
            ))
        }
        return result
    }

    var calls: [Call] { state.withLock { $0 } }
}

@Suite("Streaming session event translation")
struct StreamingTranscriptionSessionTests {
    @Test("voice activity is silent until the buffer has at least one energy sample")
    func voiceActivityWaitsForFirstSample() async {
        let (stream, cont) = AsyncStream<StreamingEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let sink = EventSink(continuation: cont)
        sink.handleEnergy(last: nil)
        cont.finish()

        var voiceEvents: [Bool] = []
        for await event in stream {
            if case .voiceActivity(let active) = event { voiceEvents.append(active) }
        }
        #expect(voiceEvents.isEmpty)
    }

    @Test("voice activity flips once when energy crosses the threshold")
    func voiceActivityFlipsOnce() async {
        let (stream, cont) = AsyncStream<StreamingEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let sink = EventSink(continuation: cont)
        sink.handleEnergy(last: 0.01)
        sink.handleEnergy(last: 0.5)
        sink.handleEnergy(last: 0.9)
        cont.finish()

        var voiceEvents: [Bool] = []
        for await event in stream {
            if case .voiceActivity(let active) = event { voiceEvents.append(active) }
        }
        #expect(voiceEvents == [false, true])
    }

    @Test("voice activity flips back to false after dropping below the threshold")
    func voiceActivityFlipsBoth() async {
        let (stream, cont) = AsyncStream<StreamingEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let sink = EventSink(continuation: cont)
        sink.handleEnergy(last: 0.5)
        sink.handleEnergy(last: 0.5)
        sink.handleEnergy(last: 0.01)
        sink.handleEnergy(last: 0.2)
        cont.finish()

        var voiceEvents: [Bool] = []
        for await event in stream {
            if case .voiceActivity(let active) = event { voiceEvents.append(active) }
        }
        #expect(voiceEvents == [true, false, true])
    }

    @Test("voice activity drops duplicate readings on the same side of the threshold")
    func voiceActivityDedupesOnSameSide() async {
        let (stream, cont) = AsyncStream<StreamingEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let sink = EventSink(continuation: cont)
        sink.handleEnergy(last: 0.4)
        sink.handleEnergy(last: 0.6)
        sink.handleEnergy(last: 0.7)
        cont.finish()

        var voiceEvents: [Bool] = []
        for await event in stream {
            if case .voiceActivity(let active) = event { voiceEvents.append(active) }
        }
        #expect(voiceEvents == [true])
    }

    @Test("partial text only fires when it changes")
    func partialDeduped() async {
        let (stream, cont) = AsyncStream<StreamingEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let sink = EventSink(continuation: cont)
        sink.handlePartial(text: "hello")
        sink.handlePartial(text: "hello")
        sink.handlePartial(text: "hello world")
        cont.finish()

        var partials: [String] = []
        for await event in stream {
            if case .partial(let t) = event { partials.append(t) }
        }
        #expect(partials == ["hello", "hello world"])
    }

    @Test("empty partial text never emits an event")
    func emptyPartialIgnored() async {
        let (stream, cont) = AsyncStream<StreamingEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let sink = EventSink(continuation: cont)
        sink.handlePartial(text: "")
        cont.finish()

        var partials: [String] = []
        for await event in stream {
            if case .partial(let t) = event { partials.append(t) }
        }
        #expect(partials.isEmpty)
    }

    @Test("partial that becomes empty after first non-empty stays unreported")
    func partialBecomingEmptyEmitsNothing() async {
        let (stream, cont) = AsyncStream<StreamingEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let sink = EventSink(continuation: cont)
        sink.handlePartial(text: "hello")
        sink.handlePartial(text: "")
        sink.handlePartial(text: "")
        cont.finish()

        var partials: [String] = []
        for await event in stream {
            if case .partial(let t) = event { partials.append(t) }
        }
        #expect(partials == ["hello"])
    }

    @Test("currentModel is nil before any session has been started")
    func currentModelStartsNil() async {
        let session = StreamingTranscriptionSession()
        let model = await session.currentModel()
        #expect(model == nil)
    }

    @Test("stop is a no-op when nothing was started, leaves the session untouched")
    func stopWithoutStartIsNoop() async {
        let session = StreamingTranscriptionSession()
        await session.stop()
        let model = await session.currentModel()
        #expect(model == nil)
    }

    @Test("the labeler receives the padded per-segment slice of the batch audio")
    func labelerGetsSegmentWindow() async {
        let sampleRate = 16_000
        let session = StreamingTranscriptionSession()
        let labeler = RecordingLabeler(result: "Speaker 1")
        let ramp = (0..<(5 * sampleRate)).map { Float($0) }
        let batch = ConfirmedAudioBatch(segments: [], audioWindow: ramp, windowStartSeconds: 1.0)
        let segment = TranscriptSegment(id: 0, start: 2.0, end: 4.0, text: "hi")

        let label = await session.labelSpeaker(for: segment, in: batch, with: labeler)
        #expect(label == "Speaker 1")
        let call = labeler.calls.first
        #expect(labeler.calls.count == 1)
        #expect(call?.windowStartTime == 1.5)
        #expect(call?.samples == Array(ramp[(sampleRate / 2)..<(7 * sampleRate / 2)]))
        #expect(call?.sampleRate == Double(sampleRate))
    }

    @Test("the segment window is clamped to the batch audio bounds")
    func labelerWindowClampedToBatch() async {
        let sampleRate = 16_000
        let session = StreamingTranscriptionSession()
        let labeler = RecordingLabeler(result: "Speaker 2")
        let ramp = (0..<(2 * sampleRate)).map { Float($0) }
        let batch = ConfirmedAudioBatch(segments: [], audioWindow: ramp, windowStartSeconds: 10.0)
        let segment = TranscriptSegment(id: 0, start: 9.0, end: 13.0, text: "hi")

        let label = await session.labelSpeaker(for: segment, in: batch, with: labeler)
        #expect(label == "Speaker 2")
        let call = labeler.calls.first
        #expect(call?.windowStartTime == 10.0)
        #expect(call?.samples == ramp)
    }

    @Test("a batch without audio never reaches the labeler")
    func emptyBatchAudioSkipsLabeler() async {
        let session = StreamingTranscriptionSession()
        let labeler = RecordingLabeler(result: "Speaker 1")
        let batch = ConfirmedAudioBatch(segments: [], audioWindow: [], windowStartSeconds: 0)
        let segment = TranscriptSegment(id: 0, start: 0, end: 1, text: "hi")

        let label = await session.labelSpeaker(for: segment, in: batch, with: labeler)
        #expect(label == nil)
        #expect(labeler.calls.isEmpty)
    }

    @Test("a segment outside the batch window is left unlabeled")
    func segmentOutsideBatchSkipsLabeler() async {
        let sampleRate = 16_000
        let session = StreamingTranscriptionSession()
        let labeler = RecordingLabeler(result: "Speaker 1")
        let batch = ConfirmedAudioBatch(
            segments: [],
            audioWindow: [Float](repeating: 0, count: sampleRate),
            windowStartSeconds: 0
        )
        let segment = TranscriptSegment(id: 0, start: 5.0, end: 6.0, text: "hi")

        let label = await session.labelSpeaker(for: segment, in: batch, with: labeler)
        #expect(label == nil)
        #expect(labeler.calls.isEmpty)
    }
}
