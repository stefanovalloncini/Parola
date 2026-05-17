import Foundation
import Testing
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
}
