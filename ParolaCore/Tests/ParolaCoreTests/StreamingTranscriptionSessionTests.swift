import Foundation
import Testing
@preconcurrency import WhisperKit
@testable import ParolaCore

@Suite("Streaming session event translation")
struct StreamingTranscriptionSessionTests {
    @Test("voice activity is silent until the buffer has at least one energy sample")
    func voiceActivityWaitsForFirstSample() async {
        let (stream, cont) = AsyncStream<StreamingEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let sink = EventSink(continuation: cont, onConfirmed: { _ in })
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
        let sink = EventSink(continuation: cont, onConfirmed: { _ in })
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
        let sink = EventSink(continuation: cont, onConfirmed: { _ in })
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
        let sink = EventSink(continuation: cont, onConfirmed: { _ in })
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
        let sink = EventSink(continuation: cont, onConfirmed: { _ in })
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
        let sink = EventSink(continuation: cont, onConfirmed: { _ in })
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
        let sink = EventSink(continuation: cont, onConfirmed: { _ in })
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
}
