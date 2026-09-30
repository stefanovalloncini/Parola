import AVFoundation
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

/// Stands in for the mic and the decoder, so a whole take runs without a model.
private final class TakeHarness: Sendable {
    private struct State {
        var ingest: (@Sendable ([Float]) -> Void)?
        var decodes = 0
        var lastDecodeSampleCount = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func install(_ ingest: @escaping @Sendable ([Float]) -> Void) {
        state.withLock { $0.ingest = ingest }
    }

    func recordDecode(sampleCount: Int) {
        state.withLock {
            $0.decodes += 1
            $0.lastDecodeSampleCount = sampleCount
        }
    }

    var installed: Bool { state.withLock { $0.ingest != nil } }
    var decodes: Int { state.withLock { $0.decodes } }
    var lastDecodeSampleCount: Int { state.withLock { $0.lastDecodeSampleCount } }

    func push(_ samples: [Float]) {
        let ingest = state.withLock { $0.ingest }
        ingest?(samples)
    }
}

private func eventually(timeoutMs: Int = 5000, _ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}

private func launchTake(
    on session: StreamingTranscriptionSession,
    persister: StreamingAudioPersister,
    harness: TakeHarness,
    useVAD: Bool = false
) async -> AsyncStream<StreamingEvent> {
    var configuration = StreamingRealtimeLoop.Configuration()
    configuration.useVAD = useVAD
    let loopConfiguration = configuration
    return await session.launch(options: TranscriptionOptions(), speakerLabeler: nil, persister: persister) { sink, confirmed in
        StreamingRealtimeLoop(
            configuration: loopConfiguration,
            decodingOptions: DecodingOptions(),
            dependencies: .init(
                requestPermission: { true },
                startCapture: { ingest in
                    harness.install { buffer in
                        if ingest(buffer) {
                            persister.append(buffer)
                        }
                    }
                },
                stopCapture: {},
                transcribe: { samples, _, _ in
                    harness.recordDecode(sampleCount: samples.count)
                    return TranscriptionResult(
                        text: " last words",
                        segments: [TranscriptionSegment(start: 0, end: 0.5, text: " last words")],
                        language: "en",
                        timings: TranscriptionTimings()
                    )
                },
                tick: { try await Task.sleep(nanoseconds: 1_000_000) }
            ),
            onPartial: { sink.handlePartial(text: $0) },
            onEnergy: { sink.handleEnergy(last: $0) },
            onConfirmed: { confirmed.yield($0) }
        )
    }
}

/// A model load that stays in flight until the test lets it finish.
private actor SuspendingLoader {
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var isLoading = false

    func load() async -> String {
        isLoading = true
        await withCheckedContinuation { waiter = $0 }
        return "kit"
    }

    func finish() {
        waiter?.resume()
        waiter = nil
    }
}

@Suite("Ending a live take")
struct StreamingTakeEndingTests {
    @Test("a stop while the model loads ends the take before capture: the load yields nothing to launch")
    func stopDuringLoadEndsTheTake() async throws {
        let session = StreamingTranscriptionSession()
        let loader = SuspendingLoader()
        let starting = Task { try await session.loadingModel { await loader.load() } }
        let loaderWait = await eventually { await loader.isLoading }
        #expect(loaderWait)

        await session.stop()
        await loader.finish()

        #expect(try await starting.value == nil)
    }

    @Test("a cancel while the model loads throws instead of launching")
    func cancelDuringLoadThrows() async throws {
        let session = StreamingTranscriptionSession()
        let loader = SuspendingLoader()
        let starting = Task { try await session.loadingModel { await loader.load() } }
        let loaderWait = await eventually { await loader.isLoading }
        #expect(loaderWait)

        await session.cancel()
        await loader.finish()

        await #expect(throws: CancellationError.self) { _ = try await starting.value }
    }

    @Test("a load nobody ended hands back what it loaded, and a stop before any start is not remembered")
    func untouchedLoadLaunches() async throws {
        let session = StreamingTranscriptionSession()
        await session.stop()
        let loader = SuspendingLoader()
        let starting = Task { try await session.loadingModel { await loader.load() } }
        let loaderWait = await eventually { await loader.isLoading }
        #expect(loaderWait)

        await loader.finish()

        #expect(try await starting.value == "kit")
    }

    @Test("a take stopped before capture finishes with an empty transcript and nothing else")
    func takeEndedBeforeCaptureOnlyFinishes() async {
        var events: [StreamingEvent] = []
        for await event in StreamingTranscriptionSession.takeEndedBeforeCapture(
            modelName: "openai_whisper-tiny", options: TranscriptionOptions(language: "it")
        ) {
            events.append(event)
        }

        #expect(events.count == 1)
        guard case .finished(let transcript) = events.first else {
            Issue.record("expected .finished, got \(events)")
            return
        }
        #expect(transcript.segments.isEmpty)
        #expect(transcript.language == "it")
        #expect(transcript.sourceURL == nil)
    }

    @Test("cancelling a take skips its final decode, deletes its audio and sends no finished transcript")
    func cancelDiscardsTheTake() async throws {
        let session = StreamingTranscriptionSession(persistAudio: true)
        let persister = try #require(StreamingAudioPersister(sampleRate: 16_000))
        let harness = TakeHarness()
        let events = await launchTake(on: session, persister: persister, harness: harness)
        let installedWait = await eventually { harness.installed }
        #expect(installedWait)
        harness.push([Float](repeating: 0.5, count: 8_000))
        let audio = persister.url

        await session.cancel()

        var finished = false
        for await event in events {
            if case .finished = event { finished = true }
        }
        #expect(!finished)
        #expect(harness.decodes == 0)
        #expect(!FileManager.default.fileExists(atPath: audio.path))
    }

    /// The app keeps a take "starting" until its first event, so a quiet start must still send one.
    @Test("a take's first event comes as soon as capture starts, in silence and before any sound")
    func firstEventArrivesAtCaptureStart() async throws {
        let session = StreamingTranscriptionSession(persistAudio: true)
        let persister = try #require(StreamingAudioPersister(sampleRate: 16_000))
        let harness = TakeHarness()
        let events = await launchTake(on: session, persister: persister, harness: harness, useVAD: true)
        let installedWait = await eventually { harness.installed }
        #expect(installedWait)
        var iterator = events.makeAsyncIterator()

        let first = await iterator.next()
        switch first {
        case .partial?, .voiceActivity?:
            break
        default:
            Issue.record("the first event of a silent start was \(String(describing: first))")
        }
        harness.push([Float](repeating: 0, count: 1_600))
        var heardSilence = false
        while let event = await iterator.next() {
            if case .voiceActivity(active: false) = event { heardSilence = true; break }
        }
        #expect(heardSilence, "silence reports itself as no voice")
        await session.cancel()
    }

    @Test("a take whose file stopped taking writes keeps what landed and says it was cut short")
    func cutShortTakeKeepsItsAudio() async throws {
        let session = StreamingTranscriptionSession(persistAudio: true)
        let persister = try #require(StreamingAudioPersister(sampleRate: 16_000, failingAfter: 1))
        let harness = TakeHarness()
        let events = await launchTake(on: session, persister: persister, harness: harness)
        let installedWait = await eventually { harness.installed }
        #expect(installedWait)
        harness.push([Float](repeating: 0.5, count: 8_000))
        harness.push([Float](repeating: 0.5, count: 8_000))
        let audio = persister.url
        defer { try? FileManager.default.removeItem(at: audio) }

        await session.stop()

        var finished: Transcript?
        for await event in events {
            if case .finished(let transcript) = event { finished = transcript }
        }
        #expect(finished?.sourceURL == audio)
        #expect(FileManager.default.fileExists(atPath: audio.path))
        #expect(await session.audioWasCutShort())
    }

    @Test("stopping the same take decodes its tail and keeps the audio")
    func stopKeepsTheTake() async throws {
        let session = StreamingTranscriptionSession(persistAudio: true)
        let persister = try #require(StreamingAudioPersister(sampleRate: 16_000))
        let harness = TakeHarness()
        let events = await launchTake(on: session, persister: persister, harness: harness)
        let installedWait = await eventually { harness.installed }
        #expect(installedWait)
        harness.push([Float](repeating: 0.5, count: 8_000))
        let audio = persister.url
        defer { try? FileManager.default.removeItem(at: audio) }

        await session.stop()

        var finished: Transcript?
        for await event in events {
            if case .finished(let transcript) = event { finished = transcript }
        }
        #expect(harness.decodes == 1)
        #expect(finished?.segments.map(\.text) == ["last words"])
        #expect(finished?.sourceURL == audio)
        #expect(FileManager.default.fileExists(atPath: audio.path))
    }

    @Test("a paused take keeps neither the sound nor the time of the pause")
    func pausedTakeSkipsThePause() async throws {
        let session = StreamingTranscriptionSession(persistAudio: true)
        let persister = try #require(StreamingAudioPersister(sampleRate: 16_000))
        let harness = TakeHarness()
        let events = await launchTake(on: session, persister: persister, harness: harness)
        let installedWait = await eventually { harness.installed }
        #expect(installedWait)
        harness.push([Float](repeating: 0.5, count: 16_000))
        await session.setPaused(true)
        harness.push([Float](repeating: 0.5, count: 16_000))
        await session.setPaused(false)
        harness.push([Float](repeating: 0.5, count: 16_000))
        await session.setPaused(true)
        harness.push([Float](repeating: 0.5, count: 16_000))
        await session.setPaused(false)
        harness.push([Float](repeating: 0.5, count: 16_000))
        let audio = persister.url
        defer { try? FileManager.default.removeItem(at: audio) }

        await session.stop()

        for await _ in events {}
        #expect(try AVAudioFile(forReading: audio).length == 48_000)
        #expect(harness.lastDecodeSampleCount == 48_000)
    }
}

@Suite("Streaming session event translation")
struct StreamingTranscriptionSessionTests {
    @Test("a finished take is stamped with the language its text reads as, not \"auto\"")
    func finalLanguageFollowsTheText() {
        let segments = [
            TranscriptSegment(id: 0, start: 0, end: 2, text: "Buongiorno a tutti, oggi parliamo della distinta base."),
            TranscriptSegment(id: 1, start: 2, end: 4, text: "I componenti sono stati ordinati al magazzino."),
        ]
        var pinned = TranscriptionOptions()
        pinned.language = "en"

        #expect(StreamingTranscriptionSession.finalLanguage(for: segments, options: pinned) == "en")
        #expect(StreamingTranscriptionSession.finalLanguage(for: segments, options: nil) == "it")
        #expect(StreamingTranscriptionSession.finalLanguage(for: [], options: nil) == "auto")
    }

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
