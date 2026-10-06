import Foundation
import Testing
@testable import ParolaCore

@Suite("Mock streaming transcriber")
struct MockStreamingTranscriberTests {
    @Test("emits partials, then confirmed segments, then finished")
    func emitsScriptedEvents() async throws {
        let response = MockTranscriberResponse(
            segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "hello world")],
            partials: ["hel", "hello", "hello world"],
            language: "en",
            durationSeconds: 1,
            modelName: "mock",
            delayMs: 0
        )
        let mock = MockStreamingTranscriber(response: response, clock: ContinuousClock())
        let stream = try await mock.start(options: TranscriptionOptions(model: "mock"),
                                          speakerLabeler: nil, downloadProgress: nil)
        let collector = Task { () -> ([String], [String], Transcript?) in
            var p: [String] = []; var c: [String] = []; var f: Transcript?
            for await event in stream {
                switch event {
                case .partial(let t): p.append(t)
                case .confirmed(let s): c.append(s.text)
                case .finished(let t): f = t
                default: break
                }
            }
            return (p, c, f)
        }
        await mock.stop()
        let (partials, confirmed, finished) = await collector.value
        #expect(partials == ["hel", "hello", "hello world"])
        #expect(confirmed == ["hello world"])
        #expect(finished?.segments.first?.text == "hello world")
    }

    @Test("cancel ends the stream without a finished transcript")
    func cancelSendsNoFinished() async throws {
        let response = MockTranscriberResponse(
            segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "hello world")],
            modelName: "mock"
        )
        let mock = MockStreamingTranscriber(response: response, clock: ContinuousClock())
        let stream = try await mock.start(options: TranscriptionOptions(model: "mock"),
                                          speakerLabeler: nil, downloadProgress: nil)
        let collector = Task { () -> Bool in
            var finished = false
            for await event in stream {
                if case .finished = event { finished = true }
            }
            return finished
        }
        await mock.cancel()
        #expect(await collector.value == false)
    }

    @Test("a canned failure emits a failed event and no confirmed segments")
    func cannedFailureEmitsFailedEvent() async throws {
        let response = MockTranscriberResponse(
            failure: MockTranscriberFailure(code: .transcriptionFailed, message: "canned boom")
        )
        let mock = MockStreamingTranscriber(response: response, clock: ContinuousClock())
        let stream = try await mock.start(options: TranscriptionOptions(model: "mock"),
                                          speakerLabeler: nil, downloadProgress: nil)
        let collector = Task { () -> ([String], [String]) in
            var failures: [String] = []; var confirmed: [String] = []
            for await event in stream {
                switch event {
                case .failed(let message): failures.append(message)
                case .confirmed(let segment): confirmed.append(segment.text)
                default: break
                }
            }
            return (failures, confirmed)
        }
        await mock.stop()
        let (failures, confirmed) = await collector.value
        #expect(failures == ["canned boom"])
        #expect(confirmed.isEmpty)
    }

    /// Starts a gated take and returns once it is held at the gate: the download report comes just before it.
    private func startHeldAtGate(
        _ mock: MockStreamingTranscriber
    ) async -> Task<AsyncStream<StreamingEvent>, any Error> {
        let (reached, reachedGate) = AsyncStream<Void>.makeStream()
        let starting = Task {
            try await mock.start(
                options: TranscriptionOptions(model: "mock"),
                speakerLabeler: nil,
                downloadProgress: { _ in reachedGate.yield() }
            )
        }
        var signal = reached.makeAsyncIterator()
        _ = await signal.next()
        return starting
    }

    @Test("a gate holds start like a model load, and events flow once it opens")
    func gateHoldsStart() async throws {
        let gate = MockTranscriberGate()
        let response = MockTranscriberResponse(partials: ["hello"], downloadFractions: [0.5], modelName: "mock", gate: gate)
        let mock = MockStreamingTranscriber(response: response, clock: ContinuousClock())
        let starting = await startHeldAtGate(mock)
        await gate.open()
        var iterator = try await starting.value.makeAsyncIterator()
        guard case .partial(let text)? = await iterator.next() else {
            Issue.record("the first event after the gate was not the partial")
            return
        }
        #expect(text == "hello")
        await mock.cancel()
    }

    @Test("a stop during the gated start ends the take before capture, with nothing in it")
    func stopDuringGatedStartFinishesEmpty() async throws {
        let response = MockTranscriberResponse(
            segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "never heard")],
            partials: ["never"],
            downloadFractions: [0.5],
            modelName: "mock",
            gate: MockTranscriberGate()
        )
        let mock = MockStreamingTranscriber(response: response, clock: ContinuousClock())
        let starting = await startHeldAtGate(mock)
        await mock.stop()
        var events: [StreamingEvent] = []
        for await event in try await starting.value { events.append(event) }
        #expect(events.count == 1)
        guard case .finished(let transcript)? = events.first else {
            Issue.record("a stop during the load did not finish the stream")
            return
        }
        #expect(transcript.segments.isEmpty)
        #expect(transcript.sourceURL == nil)
    }

    @Test("a mock that waits for its model on stop finishes with its segments once the gate opens")
    func stopWaitsForTheGate() async throws {
        let gate = MockTranscriberGate()
        let response = MockTranscriberResponse(
            segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "early words")],
            downloadFractions: [0.5],
            modelName: "mock",
            gate: gate,
            waitsForModelOnStop: true
        )
        let mock = MockStreamingTranscriber(response: response, clock: ContinuousClock())
        let starting = await startHeldAtGate(mock)
        let stopping = GuardedTask { await mock.stop() }
        await pollUntil("the stop to wait at the gate") { await mock.stopsWaitingForModelCount == 1 }

        await gate.open()

        _ = try await stopping.value("the stop to finish once the gate opens")
        var confirmed: [String] = []
        var finished: Transcript?
        for await event in try await starting.value {
            if case .confirmed(let segment) = event { confirmed.append(segment.text) }
            if case .finished(let transcript) = event { finished = transcript }
        }
        #expect(confirmed == ["early words"])
        #expect(finished?.segments.map(\.text) == ["early words"])
    }

    @Test("a cancel during the gated start throws instead of starting")
    func cancelDuringGatedStartThrows() async throws {
        let response = MockTranscriberResponse(
            partials: ["never"], downloadFractions: [0.5], modelName: "mock", gate: MockTranscriberGate()
        )
        let mock = MockStreamingTranscriber(response: response, clock: ContinuousClock())
        let starting = await startHeldAtGate(mock)
        await mock.cancel()
        await #expect(throws: CancellationError.self) { _ = try await starting.value }
    }

    @Test("a mock with recorded audio names it while it runs and ends with a transcript that carries it")
    func recordedAudioRidesAlong() async throws {
        let audio = URL(fileURLWithPath: "/tmp/parola-mock-recorded-\(UUID().uuidString).wav")
        let mock = MockStreamingTranscriber(
            response: MockTranscriberResponse(segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "kept")], recordedAudio: audio),
            clock: ContinuousClock()
        )
        let source: any StreamingTranscriber = mock
        let stream = try await mock.start(options: TranscriptionOptions(model: "mock"), speakerLabeler: nil, downloadProgress: nil)
        #expect(await source.recordingAudioURL() == audio)
        let finished = Task { () -> Transcript? in
            for await event in stream { if case .finished(let transcript) = event { return transcript } }
            return nil
        }
        await mock.stop()
        let transcript = await finished.value
        #expect(transcript?.sourceURL == audio)
    }

    @Test("setPaused records each call, in order")
    func setPausedRecordsCalls() async {
        let mock = MockStreamingTranscriber(response: MockTranscriberResponse(), clock: ContinuousClock())
        await mock.setPaused(true)
        await mock.setPaused(false)
        #expect(await mock.pauseCalls == [true, false])
    }

    @Test("a failure with canned segments confirms them before failing")
    func failureAfterSegmentsConfirmsFirst() async throws {
        let response = MockTranscriberResponse(
            segments: [TranscriptSegmentSeed(start: 0, end: 2, text: "kept take")],
            failure: MockTranscriberFailure(code: .transcriptionFailed, message: "mid-take boom")
        )
        let mock = MockStreamingTranscriber(response: response, clock: ContinuousClock())
        let stream = try await mock.start(options: TranscriptionOptions(model: "mock"),
                                          speakerLabeler: nil, downloadProgress: nil)
        let collector = Task { () -> [String] in
            var events: [String] = []
            for await event in stream {
                switch event {
                case .failed(let message): events.append("failed:\(message)")
                case .confirmed(let segment): events.append("confirmed:\(segment.text)")
                default: break
                }
            }
            return events
        }
        await mock.stop()
        let events = await collector.value
        #expect(events == ["confirmed:kept take", "failed:mid-take boom"])
    }
}
