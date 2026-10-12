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
    let captureStarted = TestSignal()

    func install(_ ingest: @escaping @Sendable ([Float]) -> Void) {
        state.withLock { $0.ingest = ingest }
        captureStarted.fire()
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

private func eventually(timeoutMs: Int = 30_000, _ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
    while !Task.isCancelled, ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}

private func launchTake(
    on session: StreamingTranscriptionSession,
    persister: StreamingAudioPersister,
    harness: TakeHarness,
    useVAD: Bool = false,
    modelLease: StreamingModelLease? = nil,
    decodeGate: UninterruptibleGate? = nil,
    speakerLabeler: (any StreamingSpeakerLabeler)? = nil,
    segmentsPerDecode: Int = 1
) async -> AsyncStream<StreamingEvent> {
    var configuration = StreamingRealtimeLoop.Configuration()
    configuration.useVAD = useVAD
    configuration.wantsConfirmedAudio = speakerLabeler != nil
    let loopConfiguration = configuration
    return await session.launch(
        options: TranscriptionOptions(), speakerLabeler: speakerLabeler, persister: persister, modelLease: modelLease
    ) { sink, confirmed in
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
                    await decodeGate?.wait()
                    harness.recordDecode(sampleCount: samples.count)
                    return TranscriptionResult(
                        text: " last words",
                        segments: (0..<segmentsPerDecode).map {
                            TranscriptionSegment(start: Float($0), end: Float($0) + 0.5, text: " last words")
                        },
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

/// Stands in for the microphone and the decoder behind `start`, so a take runs the session's own wiring without hardware or weights.
private final class StandInMic: Sendable {
    private struct State {
        var onBuffer: (@Sendable ([Float]) -> Void)?
        var decodedSampleCounts: [Int] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let granted: Bool
    private let holdsDecodes: Bool
    let captureStarted = TestSignal()
    let captureStopped = TestSignal()
    let decodes = Awaitable(0)

    /// `holdsDecodes` parks every decode until its task is cancelled.
    init(granted: Bool = true, holdsDecodes: Bool = false) {
        self.granted = granted
        self.holdsDecodes = holdsDecodes
    }

    func microphone(_ deviceID: DeviceID?) -> StreamingTranscriptionSession.Microphone {
        .init(
            requestPermission: { [granted] in granted },
            start: { [self] onBuffer in
                state.withLock { $0.onBuffer = onBuffer }
                captureStarted.fire()
            },
            stop: { [self] in captureStopped.fire() }
        )
    }

    func decoder(_ lease: StreamingModelLease, _ options: TranscriptionOptions) -> StreamingRealtimeLoop.Decoder {
        .init(options: DecodingOptions()) { [self] samples, _, _ in
            state.withLock { $0.decodedSampleCounts.append(samples.count) }
            decodes.increment()
            if holdsDecodes { try await Task.sleep(for: .seconds(3600)) }
            return TranscriptionResult(
                text: " early words",
                segments: [TranscriptionSegment(start: 0, end: 0.5, text: " early words")],
                language: "en",
                timings: TranscriptionTimings()
            )
        }
    }

    var decodedSampleCounts: [Int] { state.withLock { $0.decodedSampleCounts } }

    func push(_ samples: [Float]) {
        let onBuffer = state.withLock { $0.onBuffer }
        onBuffer?(samples)
    }

    func push(seconds: Double, value: Float) {
        push([Float](repeating: value, count: Int(seconds * 16_000)))
    }

    /// A breath of silence first: VAD hears voice against the quietest recent buffer.
    func speak(seconds: Double) {
        push(seconds: 0.1, value: 0)
        push(seconds: seconds, value: 0.5)
    }
}

/// One `read` hands back at most a chunk of the file, so this reads until it has `count` frames or the file ends.
private func firstSamples(_ count: Int, in file: URL) throws -> [Float] {
    let audio = try AVAudioFile(forReading: file)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(count)))
    var samples: [Float] = []
    while samples.count < count {
        try audio.read(into: buffer, frameCount: AVAudioFrameCount(count - samples.count))
        guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { break }
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
    return samples
}

private func finishedTranscript(of events: AsyncStream<StreamingEvent>) async -> Transcript? {
    var finished: Transcript?
    for await event in events {
        if case .finished(let transcript) = event { finished = transcript }
    }
    return finished
}

@Suite("Ending a live take")
struct StreamingTakeEndingTests {
    @Test("a stop during the model download ends the take before capture: the download yields nothing to launch")
    func stopDuringDownloadEndsTheTake() async throws {
        let session = StreamingTranscriptionSession()
        let loader = SuspendingLoader()
        let starting = Task { try await session.loadingModel { await loader.load() } }
        let loaderIsLoading = await eventually { await loader.isLoading }
        #expect(loaderIsLoading)

        await session.stop()
        await loader.finish()

        #expect(try await starting.value == nil)
    }

    @Test("a cancel during the model download throws instead of launching")
    func cancelDuringDownloadThrows() async throws {
        let session = StreamingTranscriptionSession()
        let loader = SuspendingLoader()
        let starting = Task { try await session.loadingModel { await loader.load() } }
        let loaderIsLoading = await eventually { await loader.isLoading }
        #expect(loaderIsLoading)

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
        let loaderIsLoading = await eventually { await loader.isLoading }
        #expect(loaderIsLoading)

        await loader.finish()

        #expect(try await starting.value == "kit")
    }

    private static let tiny = "openai_whisper-tiny"

    private static func seededStore() throws -> ModelStore {
        let store = ModelStore(modelsDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-streaming-lease-\(UUID().uuidString)"))
        try store.seedInstalledModel(tiny)
        return store
    }

    @Test("a take stopped during the model load returns its lease")
    func stopDuringLoadReturnsTheLease() async throws {
        let probe = CacheProbe()
        let gate = LoadGate()
        let cache = StreamingModelCache.probing(probe, gate: gate)
        let session = StreamingTranscriptionSession(
            modelStore: try Self.seededStore(), modelCache: cache, microphone: StandInMic().microphone
        )
        let starting = GuardedTask { try await session.start(options: TranscriptionOptions(model: Self.tiny)) }
        await probe.loads.wait(atLeast: 1, "the model load to start")

        let stopping = GuardedTask { await session.stop() }
        _ = try await stopping.value("the stop to return without the model")
        await gate.open(Self.tiny)

        let events = try #require(try await starting.value("the start to return"))
        var finished = false
        for await event in events {
            if case .finished = event { finished = true }
        }
        #expect(finished)
        #expect(await cache.leaseCount(for: Self.tiny) == 0)
        #expect(await cache.droppedLeases == 0, "returned by the session, not by the lease's deinit")
    }

    @Test("a take cancelled during the model load returns its lease")
    func cancelDuringLoadReturnsTheLease() async throws {
        let probe = CacheProbe()
        let gate = LoadGate()
        let cache = StreamingModelCache.probing(probe, gate: gate)
        let session = StreamingTranscriptionSession(
            modelStore: try Self.seededStore(), modelCache: cache, microphone: StandInMic().microphone
        )
        let starting = GuardedTask { try await session.start(options: TranscriptionOptions(model: Self.tiny)) }
        await probe.loads.wait(atLeast: 1, "the model load to start")

        let cancelling = GuardedTask { await session.cancel() }
        _ = try await cancelling.value("the cancel to return without the model")
        await gate.open(Self.tiny)

        await #expect(throws: CancellationError.self) { _ = try await starting.value("the start to return") }
        #expect(await cache.leaseCount(for: Self.tiny) == 0)
        #expect(await cache.droppedLeases == 0, "returned by the session, not by the lease's deinit")
    }

    @Test("a start that fails after the borrow returns its lease")
    func failedStartReturnsTheLease() async throws {
        let probe = CacheProbe()
        let cache = StreamingModelCache.probing(probe)
        let session = StreamingTranscriptionSession(
            modelStore: try Self.seededStore(), modelCache: cache, microphone: StandInMic().microphone
        )

        await #expect(throws: ParolaError.self) {
            _ = try await session.start(options: TranscriptionOptions(model: Self.tiny))
        }
        #expect(probe.loads.value == 1, "the borrow happened before the tokenizer check failed")
        #expect(await cache.leaseCount(for: Self.tiny) == 0)
        #expect(await cache.droppedLeases == 0, "returned by the session, not by the lease's deinit")
    }

    @Test("teardown releases the lease", arguments: [true, false])
    func teardownReleasesTheLease(stopping: Bool) async throws {
        let cache = StreamingModelCache.probing(CacheProbe())
        let lease = try await cache.borrow(Self.tiny, store: try Self.seededStore())
        let session = StreamingTranscriptionSession(persistAudio: true)
        let persister = try #require(StreamingAudioPersister(sampleRate: 16_000))
        defer { try? FileManager.default.removeItem(at: persister.url) }
        let harness = TakeHarness()
        let events = await launchTake(on: session, persister: persister, harness: harness, modelLease: lease)
        await harness.captureStarted.wait("capture to start")
        #expect(await cache.leaseCount(for: Self.tiny) == 1, "the running take holds the model")

        if stopping {
            await session.stop()
        } else {
            await session.cancel()
        }

        for await _ in events {}
        #expect(await cache.leaseCount(for: Self.tiny) == 0)
        #expect(await cache.droppedLeases == 0, "returned by the session, not by the lease's deinit")
    }

    @Test("a start while the last take is still stopping is refused before it borrows")
    func startDuringAStopIsRefused() async throws {
        let probe = CacheProbe()
        let cache = StreamingModelCache.probing(probe)
        let store = try Self.seededStore()
        try store.seedInstalledModel("openai_whisper-base")
        let lease = try await cache.borrow(Self.tiny, store: store)
        let session = StreamingTranscriptionSession(modelStore: store, persistAudio: true, modelCache: cache)
        let persister = try #require(StreamingAudioPersister(sampleRate: 16_000))
        defer { try? FileManager.default.removeItem(at: persister.url) }
        let harness = TakeHarness()
        let decodeGate = UninterruptibleGate()
        defer { decodeGate.open() }
        let events = await launchTake(
            on: session, persister: persister, harness: harness, modelLease: lease, decodeGate: decodeGate
        )
        await harness.captureStarted.wait("capture to start")
        harness.push([Float](repeating: 0.5, count: 8_000))
        let stopping = GuardedTask { await session.stop() }
        await decodeGate.arrivals.wait(atLeast: 1, "the stop's final decode to start")

        await #expect(throws: ParolaError.self) {
            _ = try await session.start(options: TranscriptionOptions(model: "openai_whisper-base"))
        }
        #expect(probe.loads.value == 1, "the refused start never borrowed")
        #expect(await cache.leaseCount(for: Self.tiny) == 1, "the stopping take still holds its model")

        decodeGate.open()
        _ = try await stopping.value("the stop to finish")
        for await _ in events {}
        #expect(await cache.leaseCount(for: Self.tiny) == 0)
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

    @Test("cancelling a take returns while its speaker labeler is still embedding")
    func cancelDoesNotWaitForTheLabeler() async throws {
        let embedding = TestSignal()
        let gate = TestSignal()
        let labeler = IncrementalSpeakerLabeler { _ in
            embedding.fire()
            await gate.wait("the test to release the embedding")
            return [1, 0]
        }
        let session = StreamingTranscriptionSession(persistAudio: false)
        let persister = try #require(StreamingAudioPersister(sampleRate: 16_000))
        let harness = TakeHarness()
        let events = await launchTake(
            on: session, persister: persister, harness: harness, speakerLabeler: labeler, segmentsPerDecode: 3
        )
        let installedWait = await eventually { harness.installed }
        #expect(installedWait)
        harness.push([Float](repeating: 0.5, count: 48_000))
        await embedding.wait("the labeler to start embedding")

        let cancelling = GuardedTask { await session.cancel() }
        _ = try await cancelling.value("the cancel to return while the embedding is held")
        #expect(!gate.fired)
        gate.fire()
        for await _ in events {}
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

    @Test("a buffer the text took is always written, even one that reaches the file as a pause lands")
    func fileNeverSecondGuessesTheText() async throws {
        let session = StreamingTranscriptionSession(persistAudio: true)
        let persister = try #require(StreamingAudioPersister(sampleRate: 16_000))
        let harness = TakeHarness()
        let events = await launchTake(on: session, persister: persister, harness: harness)
        let installedWait = await eventually { harness.installed }
        #expect(installedWait)
        harness.push([Float](repeating: 0.5, count: 16_000))
        await session.setPaused(true)
        persister.append([Float](repeating: 0.5, count: 1_600))
        await session.setPaused(false)
        harness.push([Float](repeating: 0.5, count: 16_000))
        let audio = persister.url
        defer { try? FileManager.default.removeItem(at: audio) }

        await session.stop()

        for await _ in events {}
        #expect(try AVAudioFile(forReading: audio).length == 33_600)
    }
}

@Suite("Capturing while the model loads")
struct StreamingCaptureFirstTests {
    private struct ModelLoadFailure: Error {}

    private static let tiny = "openai_whisper-tiny"

    private static func session(
        cache: StreamingModelCache,
        mic: StandInMic,
        persistAudio: Bool = false,
        waitsForModelOnStop: Bool = false,
        clock: any Clock<Duration> = ContinuousClock()
    ) throws -> StreamingTranscriptionSession {
        let store = ModelStore(modelsDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-capture-first-\(UUID().uuidString)"))
        try store.seedInstalledModel(tiny)
        return StreamingTranscriptionSession(
            modelStore: store, persistAudio: persistAudio, waitsForModelOnStop: waitsForModelOnStop, modelCache: cache,
            microphone: mic.microphone, makeDecoder: mic.decoder, clock: clock
        )
    }

    @Test("audio captured before the model is ready is transcribed once it loads")
    func earlyAudioIsTranscribed() async throws {
        let probe = CacheProbe()
        let gate = LoadGate()
        let cache = StreamingModelCache.probing(probe, gate: gate)
        let mic = StandInMic()
        let session = try Self.session(cache: cache, mic: mic)
        let starting = GuardedTask { try await session.start(options: TranscriptionOptions(model: Self.tiny)) }
        await probe.loads.wait(atLeast: 1, "the model load to start")

        mic.speak(seconds: 2)
        #expect(mic.decodes.value == 0, "nothing decodes before the model is in")
        await gate.open(Self.tiny)

        let events = try #require(try await starting.value("the start to return"))
        await mic.decodes.wait(atLeast: 1, "the early audio to decode")
        #expect(mic.decodedSampleCounts.first == 33_600, "the first decode gets everything said during the load")
        await session.stop()

        let finished = await finishedTranscript(of: events)
        #expect(finished?.segments.map(\.text) == ["early words"])
        #expect(finished?.segments.first?.start == 0)
        #expect(await cache.leaseCount(for: Self.tiny) == 0)
    }

    @Test("capture starts before the model finishes loading")
    func captureStartsFirst() async throws {
        let probe = CacheProbe()
        let gate = LoadGate()
        let mic = StandInMic()
        let captureUpAtLoad = Awaitable<Bool?>(nil)
        let cache = StreamingModelCache(loader: { name, _ in
            captureUpAtLoad.update { $0 = mic.captureStarted.fired }
            probe.loads.increment()
            await gate.wait(name)
            return try await StreamingModelCache.makeUnloadedKit()
        })
        let session = try Self.session(cache: cache, mic: mic)
        let starting = GuardedTask { try await session.start(options: TranscriptionOptions(model: Self.tiny)) }
        await probe.loads.wait(atLeast: 1, "the model load to start")

        #expect(captureUpAtLoad.value == true, "the microphone was up before the load began")
        #expect(mic.captureStarted.fired)
        #expect(!mic.captureStopped.fired)
        #expect(!starting.isFinished, "the start waits for the model")

        await gate.open(Self.tiny)
        let events = try #require(try await starting.value("the start to return"))
        await session.stop()
        for await _ in events {}
        #expect(mic.captureStopped.fired)
    }

    @Test("a denied microphone never loads a model")
    func deniedMicrophoneLoadsNothing() async throws {
        let probe = CacheProbe()
        let cache = StreamingModelCache.probing(probe)
        let mic = StandInMic(granted: false)
        let session = try Self.session(cache: cache, mic: mic)

        let starting = GuardedTask { try await session.start(options: TranscriptionOptions(model: Self.tiny)) }
        let events = try #require(try await starting.value("the start to return"))
        var failed = false
        for await event in events {
            if case .failed = event { failed = true }
        }

        #expect(failed, "the denial still reaches the stream")
        #expect(probe.loads.value == 0)
        #expect(!mic.captureStarted.fired)
        #expect(await cache.leaseCount(for: Self.tiny) == 0)
    }

    @Test("stop during the model load releases the lease and stops capture")
    func stopDuringLoadReleasesAndStops() async throws {
        let probe = CacheProbe()
        let gate = LoadGate()
        let cache = StreamingModelCache.probing(probe, gate: gate)
        let mic = StandInMic()
        let session = try Self.session(cache: cache, mic: mic)
        let starting = GuardedTask { try await session.start(options: TranscriptionOptions(model: Self.tiny)) }
        await probe.loads.wait(atLeast: 1, "the model load to start")
        mic.speak(seconds: 1)

        let stopping = GuardedTask { await session.stop() }
        _ = try await stopping.value("the stop to return without the model")

        #expect(mic.captureStopped.fired)
        #expect(await cache.leaseCount(for: Self.tiny) == 0, "the borrow in flight was given back by the time stop returned")
        let events = try #require(try await starting.value("the start to return"))
        let finished = await finishedTranscript(of: events)
        #expect(finished?.segments.isEmpty == true, "what was buffered is dropped, not decoded")
        #expect(mic.decodes.value == 0)

        #expect(await cache.droppedLeases == 0)
        await gate.open(Self.tiny)
    }

    @Test("a take stopped during the model load waits for the model and lands with the words it buffered")
    func stoppedTakeWaitsForItsModel() async throws {
        let probe = CacheProbe()
        let gate = LoadGate()
        let cache = StreamingModelCache.probing(probe, gate: gate)
        let mic = StandInMic()
        let session = try Self.session(cache: cache, mic: mic, persistAudio: true)
        let starting = GuardedTask { try await session.start(options: TranscriptionOptions(model: Self.tiny)) }
        await probe.loads.wait(atLeast: 1, "the model load to start")
        mic.speak(seconds: 2)

        let stopping = GuardedTask { await session.stop() }
        await mic.captureStopped.wait("capture to stop at once")
        #expect(!stopping.isFinished, "the stop waits for the model")
        #expect(mic.decodes.value == 0)
        await gate.open(Self.tiny)
        _ = try await stopping.value("the stop to finish once the model is in")

        let events = try #require(try await starting.value("the start to return"))
        let finished = await finishedTranscript(of: events)
        #expect(finished?.segments.map(\.text) == ["early words"])
        #expect(mic.decodedSampleCounts == [33_600], "one flush decodes everything said before the stop")
        let audio = try #require(finished?.sourceURL)
        defer { try? FileManager.default.removeItem(at: audio) }
        #expect(try AVAudioFile(forReading: audio).length == 33_600)
        #expect(await cache.leaseCount(for: Self.tiny) == 0)
        #expect(await cache.droppedLeases == 0)
    }

    @Test("a take cancelled during the model load still ends at once and deletes its audio")
    func cancelledTakeEndsAtOnce() async throws {
        let probe = CacheProbe()
        let gate = LoadGate()
        let cache = StreamingModelCache.probing(probe, gate: gate)
        let mic = StandInMic()
        let session = try Self.session(cache: cache, mic: mic, persistAudio: true)
        let transcriber: any StreamingTranscriber = session
        let starting = GuardedTask { try await session.start(options: TranscriptionOptions(model: Self.tiny)) }
        await probe.loads.wait(atLeast: 1, "the model load to start")
        mic.speak(seconds: 1)
        let audio = try #require(await transcriber.recordingAudioURL())

        let cancelling = GuardedTask { await session.cancel() }
        _ = try await cancelling.value("the cancel to return without the model")

        await #expect(throws: CancellationError.self) { _ = try await starting.value("the start to return") }
        #expect(mic.captureStopped.fired)
        #expect(mic.decodes.value == 0)
        #expect(!FileManager.default.fileExists(atPath: audio.path))
        #expect(await cache.leaseCount(for: Self.tiny) == 0)
        #expect(await cache.droppedLeases == 0)
        await gate.open(Self.tiny)
    }

    @Test("a take that loads normally keeps the audio from before the model at the start of its file")
    func normalTakeFileStartsBeforeTheModel() async throws {
        let probe = CacheProbe()
        let gate = LoadGate()
        let cache = StreamingModelCache.probing(probe, gate: gate)
        let mic = StandInMic()
        let session = try Self.session(cache: cache, mic: mic, persistAudio: true)
        let starting = GuardedTask { try await session.start(options: TranscriptionOptions(model: Self.tiny)) }
        await probe.loads.wait(atLeast: 1, "the model load to start")
        let early = (0..<16_000).map { Float($0) / 32_000 }
        mic.push(early)

        await gate.open(Self.tiny)
        let events = try #require(try await starting.value("the start to return"))
        mic.push(seconds: 1, value: 0.25)
        let stopping = GuardedTask { await session.stop() }
        _ = try await stopping.value("the stop to finish")

        let finished = await finishedTranscript(of: events)
        let audio = try #require(finished?.sourceURL)
        defer { try? FileManager.default.removeItem(at: audio) }
        #expect(try AVAudioFile(forReading: audio).length == 32_000)
        #expect(try firstSamples(16_000, in: audio) == early)
    }

    @Test("a pause during the model load keeps the paused audio out of the buffer and the file")
    func pauseDuringLoad() async throws {
        let probe = CacheProbe()
        let gate = LoadGate()
        let cache = StreamingModelCache.probing(probe, gate: gate)
        let mic = StandInMic()
        let session = try Self.session(cache: cache, mic: mic, persistAudio: true)
        let starting = GuardedTask { try await session.start(options: TranscriptionOptions(model: Self.tiny)) }
        await probe.loads.wait(atLeast: 1, "the model load to start")

        mic.speak(seconds: 1)
        await session.setPaused(true)
        mic.push(seconds: 1, value: 0.5)
        await session.setPaused(false)
        mic.push(seconds: 1, value: 0.5)
        await gate.open(Self.tiny)

        let events = try #require(try await starting.value("the start to return"))
        await mic.decodes.wait(atLeast: 1, "the held audio to decode")
        #expect(mic.decodedSampleCounts.first == 33_600)
        let stopping = GuardedTask { await session.stop() }
        _ = try await stopping.value("the stop to finish")
        let finished = await finishedTranscript(of: events)
        let audio = try #require(finished?.sourceURL)
        defer { try? FileManager.default.removeItem(at: audio) }
        #expect(try AVAudioFile(forReading: audio).length == 33_600)
    }

    @Test("the level meter moves while the model loads")
    func meterMovesDuringLoad() async throws {
        let probe = CacheProbe()
        let gate = LoadGate()
        let cache = StreamingModelCache.probing(probe, gate: gate)
        let mic = StandInMic()
        let session = try Self.session(cache: cache, mic: mic)
        let starting = GuardedTask { try await session.start(options: TranscriptionOptions(model: Self.tiny)) }
        await probe.loads.wait(atLeast: 1, "the model load to start")
        #expect(session.levelMeter.firstReadingAt == nil)

        mic.push(seconds: 0.1, value: 0.5)

        #expect(session.levelMeter.firstReadingAt != nil)
        #expect(session.levelMeter.level > 0)
        #expect(!starting.isFinished, "the model is still loading")
        await gate.open(Self.tiny)
        let events = try #require(try await starting.value("the start to return"))
        let stopping = GuardedTask { await session.stop() }
        _ = try await stopping.value("the stop to finish")
        for await _ in events {}
    }

    @Test("a cancel while a stopped take waits for its model discards the take and returns at once")
    func cancelReachesAWaitingStop() async throws {
        let probe = CacheProbe()
        let gate = LoadGate()
        let cache = StreamingModelCache.probing(probe, gate: gate)
        let mic = StandInMic()
        let session = try Self.session(cache: cache, mic: mic, persistAudio: true)
        let transcriber: any StreamingTranscriber = session
        let starting = GuardedTask { try await session.start(options: TranscriptionOptions(model: Self.tiny)) }
        await probe.loads.wait(atLeast: 1, "the model load to start")
        mic.speak(seconds: 1)
        let audio = try #require(await transcriber.recordingAudioURL())
        let stopping = GuardedTask { await session.stop() }
        await mic.captureStopped.wait("capture to stop at once")

        let cancelling = GuardedTask { await session.cancel() }
        _ = try await cancelling.value("the cancel to return without the model")

        _ = try await stopping.value("the stop to end with the cancel")
        await #expect(throws: CancellationError.self) { _ = try await starting.value("the start to return") }
        #expect(!FileManager.default.fileExists(atPath: audio.path), "a cancel after a stop discards, as a plain cancel does")
        #expect(mic.decodes.value == 0)
        #expect(await cache.leaseCount(for: Self.tiny) == 0)
        await gate.open(Self.tiny)
    }

    @Test("a start cancelled while its stopped take waits for the model discards the take")
    func cancelledStartReachesAWaitingStop() async throws {
        let probe = CacheProbe()
        let gate = LoadGate()
        let cache = StreamingModelCache.probing(probe, gate: gate)
        let mic = StandInMic()
        let session = try Self.session(cache: cache, mic: mic, persistAudio: true)
        let transcriber: any StreamingTranscriber = session
        let starting = GuardedTask { try await session.start(options: TranscriptionOptions(model: Self.tiny)) }
        await probe.loads.wait(atLeast: 1, "the model load to start")
        mic.speak(seconds: 1)
        let audio = try #require(await transcriber.recordingAudioURL())
        let stopping = GuardedTask { await session.stop() }
        await mic.captureStopped.wait("capture to stop at once")

        starting.cancel()

        await #expect(throws: CancellationError.self) { _ = try await starting.value("the start to return") }
        _ = try await stopping.value("the stop to end with the cancelled start")
        #expect(!FileManager.default.fileExists(atPath: audio.path))
        #expect(await cache.leaseCount(for: Self.tiny) == 0)
        await gate.open(Self.tiny)
    }

    @Test("a stopped take whose model never loads ends at the limit with its audio and no words")
    func stoppedTakeGivesUpOnAStalledModel() async throws {
        let probe = CacheProbe()
        let gate = LoadGate()
        let cache = StreamingModelCache.probing(probe, gate: gate)
        let mic = StandInMic()
        let clock = TestClock()
        let session = try Self.session(cache: cache, mic: mic, persistAudio: true, clock: clock)
        let starting = GuardedTask { try await session.start(options: TranscriptionOptions(model: Self.tiny)) }
        await probe.loads.wait(atLeast: 1, "the model load to start")
        mic.speak(seconds: 1)
        let stopping = GuardedTask { await session.stop() }
        await clock.waitForSleeper()

        clock.advance(by: .seconds(119))
        #expect(!stopping.isFinished, "still within the wait")
        clock.advance(by: .seconds(1))
        _ = try await stopping.value("the stop to give up on the model")

        let events = try #require(try await starting.value("the start to return"))
        let finished = await finishedTranscript(of: events)
        #expect(finished?.segments.isEmpty == true)
        #expect(finished?.modelName == "", "no model ran on it, so it is not transcribed rather than empty of speech")
        let audio = try #require(finished?.sourceURL, "the take keeps its audio")
        defer { try? FileManager.default.removeItem(at: audio) }
        #expect(try AVAudioFile(forReading: audio).length == 17_600)
        #expect(mic.decodes.value == 0)
        #expect(await cache.leaseCount(for: Self.tiny) == 0)
        #expect(await cache.droppedLeases == 0)
        await gate.open(Self.tiny)
    }

    @Test("a cancel during a stopped take's final decode discards the take")
    func cancelDuringTheFinalDecodeDiscards() async throws {
        let cache = StreamingModelCache.probing(CacheProbe())
        let mic = StandInMic(holdsDecodes: true)
        let session = try Self.session(cache: cache, mic: mic, persistAudio: true)
        let transcriber: any StreamingTranscriber = session
        let starting = GuardedTask { try await session.start(options: TranscriptionOptions(model: Self.tiny)) }
        let events = try #require(try await starting.value("the start to return"))
        mic.speak(seconds: 0.8)
        let audio = try #require(await transcriber.recordingAudioURL())
        let stopping = GuardedTask { await session.stop() }
        await mic.decodes.wait(atLeast: 1, "the stop's final decode to start")

        let cancelling = GuardedTask { await session.cancel() }
        _ = try await cancelling.value("the cancel to return")
        _ = try await stopping.value("the stop to end with the cancel")

        var finished = false
        for await event in events {
            if case .finished = event { finished = true }
        }
        #expect(!finished, "a cancelled take sends no finished transcript")
        #expect(!FileManager.default.fileExists(atPath: audio.path))
        #expect(await cache.leaseCount(for: Self.tiny) == 0)
    }

    @Test("a session asked to wait for its model on stop keeps every word without keeping audio")
    func waitingStopWithoutAudio() async throws {
        let probe = CacheProbe()
        let gate = LoadGate()
        let cache = StreamingModelCache.probing(probe, gate: gate)
        let mic = StandInMic()
        let session = try Self.session(cache: cache, mic: mic, waitsForModelOnStop: true)
        let starting = GuardedTask { try await session.start(options: TranscriptionOptions(model: Self.tiny)) }
        await probe.loads.wait(atLeast: 1, "the model load to start")
        mic.speak(seconds: 2)

        let stopping = GuardedTask { await session.stop() }
        await mic.captureStopped.wait("capture to stop at once")
        await gate.open(Self.tiny)
        _ = try await stopping.value("the stop to finish once the model is in")

        let events = try #require(try await starting.value("the start to return"))
        let finished = await finishedTranscript(of: events)
        #expect(finished?.segments.map(\.text) == ["early words"])
        #expect(finished?.sourceURL == nil)
        #expect(await cache.leaseCount(for: Self.tiny) == 0)
    }

    @Test("a start cancelled during the model load stops capture and returns its lease")
    func cancelledStartStopsCapture() async throws {
        let probe = CacheProbe()
        let gate = LoadGate()
        let cache = StreamingModelCache.probing(probe, gate: gate)
        let mic = StandInMic()
        let session = try Self.session(cache: cache, mic: mic)
        let starting = GuardedTask { try await session.start(options: TranscriptionOptions(model: Self.tiny)) }
        await probe.loads.wait(atLeast: 1, "the model load to start")

        starting.cancel()

        await #expect(throws: CancellationError.self) { _ = try await starting.value("the start to return") }
        #expect(mic.captureStopped.fired)
        #expect(await cache.leaseCount(for: Self.tiny) == 0)
        await gate.open(Self.tiny)
    }

    private static func failingCache(gate: LoadGate, loads: Awaitable<Int>) -> StreamingModelCache {
        StreamingModelCache(loader: { name, _ in
            loads.increment()
            await gate.wait(name)
            throw ModelLoadFailure()
        })
    }

    @Test("a model load failure after capture started stops capture, reports the failure and keeps the take's audio")
    func loadFailureStopsCapture() async throws {
        let gate = LoadGate()
        let loads = Awaitable(0)
        let cache = Self.failingCache(gate: gate, loads: loads)
        let mic = StandInMic()
        let session = try Self.session(cache: cache, mic: mic, persistAudio: true)
        // Through the protocol, as the app asks: on the concrete actor an async call picks the extension's nil default.
        let transcriber: any StreamingTranscriber = session
        let starting = GuardedTask { try await session.start(options: TranscriptionOptions(model: Self.tiny)) }
        await loads.wait(atLeast: 1, "the model load to start")
        mic.speak(seconds: 1)
        let audio = try #require(await transcriber.recordingAudioURL())
        defer { try? FileManager.default.removeItem(at: audio) }

        await gate.open(Self.tiny)

        await #expect(throws: ModelLoadFailure.self) { _ = try await starting.value("the start to fail") }
        #expect(mic.captureStopped.fired)
        #expect(mic.decodes.value == 0)
        #expect(await cache.leaseCount(for: Self.tiny) == 0)
        #expect(await transcriber.recordingAudioURL() == audio, "the failure leaves the file where the caller can find it")
        #expect(try AVAudioFile(forReading: audio).length == 17_600)
    }

    @Test("a take stopped while its model then fails to load keeps its audio and still reports the failure")
    func stopThenLoadFailureKeepsAudio() async throws {
        let gate = LoadGate()
        let loads = Awaitable(0)
        let cache = Self.failingCache(gate: gate, loads: loads)
        let mic = StandInMic()
        let session = try Self.session(cache: cache, mic: mic, persistAudio: true)
        let transcriber: any StreamingTranscriber = session
        let starting = GuardedTask { try await session.start(options: TranscriptionOptions(model: Self.tiny)) }
        await loads.wait(atLeast: 1, "the model load to start")
        mic.speak(seconds: 1)
        let audio = try #require(await transcriber.recordingAudioURL())
        defer { try? FileManager.default.removeItem(at: audio) }

        let stopping = GuardedTask { await session.stop() }
        await mic.captureStopped.wait("capture to stop at once")
        await gate.open(Self.tiny)
        _ = try await stopping.value("the stop to finish once the load fails")

        await #expect(throws: ModelLoadFailure.self) { _ = try await starting.value("the start to fail") }
        #expect(await transcriber.recordingAudioURL() == audio)
        #expect(try AVAudioFile(forReading: audio).length == 17_600)
        #expect(await cache.leaseCount(for: Self.tiny) == 0)
    }

    @Test("the pre-model buffer keeps at most 60 s")
    func preModelBufferIsBounded() async throws {
        let probe = CacheProbe()
        let gate = LoadGate()
        let cache = StreamingModelCache.probing(probe, gate: gate)
        let mic = StandInMic()
        let session = try Self.session(cache: cache, mic: mic)
        let starting = GuardedTask { try await session.start(options: TranscriptionOptions(model: Self.tiny)) }
        await probe.loads.wait(atLeast: 1, "the model load to start")

        mic.push(seconds: 0.1, value: 0)
        for _ in 0..<70 { mic.push(seconds: 1, value: 0.5) }
        await gate.open(Self.tiny)

        let events = try #require(try await starting.value("the start to return"))
        await mic.decodes.wait(atLeast: 1, "the held audio to decode")
        #expect(mic.decodedSampleCounts.first == 60 * 16_000)
        await session.stop()

        let finished = await finishedTranscript(of: events)
        let start = try #require(finished?.segments.first?.start)
        #expect(abs(start - 10.1) < 0.001, "timestamps still count from the first buffer the microphone gave")
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
