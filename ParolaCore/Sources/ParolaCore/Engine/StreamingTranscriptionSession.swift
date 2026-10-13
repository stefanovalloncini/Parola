import Foundation
import AVFoundation
import os
@preconcurrency import WhisperKit

/// Labels a confirmed live-caption segment with a speaker.
///
/// Receives the segment plus the rolling audio buffer the streaming session has captured so far,
/// and the timeline offset that audio buffer starts at. Returns the speaker label to attach to the
/// segment, or nil to leave it unlabeled.
public protocol StreamingSpeakerLabeler: Sendable {
    func labelSpeaker(
        for segment: TranscriptSegment,
        audioWindow: ArraySlice<Float>,
        windowStartTime: TimeInterval,
        sampleRate: Double
    ) async -> String?
}

/// Drives real-time microphone transcription with a windowed loop over WhisperKit's decoder.
///
/// Lifecycle:
/// ```
/// let session = StreamingTranscriptionSession()
/// let stream = try await session.start(options: opts)
/// for await event in stream { … }
/// await session.stop()
/// ```
///
/// One session = one mic capture. Construct a new one to record again.
public actor StreamingTranscriptionSession: StreamingTranscriber {
    /// What a take records from; tests stand in for the hardware.
    struct Microphone: Sendable {
        var requestPermission: @Sendable () async -> Bool
        var start: @Sendable (_ onBuffer: @escaping @Sendable ([Float]) -> Void) throws -> Void
        var stop: @Sendable () -> Void

        static func input(_ deviceID: DeviceID?) -> Microphone {
            // Capture must not share the cached kit's AudioProcessor: its AVAudioEngine and sample
            // buffer are per-recording state, and another session could be borrowing the same kit.
            nonisolated(unsafe) let processor = AudioProcessor()
            return Microphone(
                requestPermission: { await AudioProcessor.requestRecordPermission() },
                start: { onBuffer in
                    try processor.startRecordingLive(inputDeviceID: deviceID) { buffer in
                        onBuffer(buffer)
                        // Runs on the tap thread, serialized with processBuffer's appends, so this purge can't race them.
                        processor.purgeAudioSamples(keepingLast: 1)
                    }
                },
                stop: { processor.stopRecording() }
            )
        }
    }

    typealias MakeDecoder = @Sendable (StreamingModelLease, TranscriptionOptions) throws -> StreamingRealtimeLoop.Decoder

    public let modelStore: ModelStore
    nonisolated let deviceUID: String?
    public nonisolated let levelMeter = LevelMeter()

    private let modelCache: StreamingModelCache
    private let microphone: @Sendable (DeviceID?) -> Microphone
    private let makeDecoder: MakeDecoder
    private let clock: any Clock<Duration>
    private var modelLease: StreamingModelLease?
    private var persister: StreamingAudioPersister?
    private var loop: StreamingRealtimeLoop?
    /// The loop a stop still waits on for the model, so a cancel can reach it.
    private var stoppingLoop: StreamingRealtimeLoop?
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: AsyncStream<StreamingEvent>.Continuation?
    private var segmentContinuation: AsyncStream<ConfirmedAudioBatch>.Continuation?
    private var consumerTask: Task<Void, Never>?
    private var streamerTask: Task<StreamingRealtimeLoop.Outcome, Never>?
    private var allConfirmed: [TranscriptSegment] = []
    private var nextSegmentID: Int = 0
    private var loadedModel: String?
    private var optionsForRun: TranscriptionOptions?
    private var speakerLabeler: (any StreamingSpeakerLabeler)?
    private var failureAudioURL: URL?
    private var audioCutShort = false
    private var startedAt: ContinuousClock.Instant?
    private var isStarting = false
    private var pendingEnd: PendingEnd?
    nonisolated let persistAudio: Bool
    nonisolated let waitsForModelOnStop: Bool

    enum PendingEnd { case stop, cancel }

    /// A take that persists audio, or one that asks to, keeps what it captured while the model loads: a stop then waits
    /// for the model and decodes it. Otherwise a stop during the load drops that audio.
    public init(
        modelStore: ModelStore = .shared, persistAudio: Bool = false, deviceUID: String? = nil, waitsForModelOnStop: Bool = false
    ) {
        self.init(
            modelStore: modelStore, persistAudio: persistAudio, deviceUID: deviceUID,
            waitsForModelOnStop: waitsForModelOnStop, modelCache: .shared
        )
    }

    init(
        modelStore: ModelStore = .shared,
        persistAudio: Bool = false,
        deviceUID: String? = nil,
        waitsForModelOnStop: Bool = false,
        modelCache: StreamingModelCache,
        microphone: @escaping @Sendable (DeviceID?) -> Microphone = Microphone.input,
        makeDecoder: @escaping MakeDecoder = StreamingTranscriptionSession.whisperDecoder,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.modelStore = modelStore
        self.persistAudio = persistAudio
        self.deviceUID = deviceUID
        self.waitsForModelOnStop = persistAudio || waitsForModelOnStop
        self.modelCache = modelCache
        self.microphone = microphone
        self.makeDecoder = makeDecoder
        self.clock = clock
    }

    /// A decoder of our own over the borrowed model, so this session's logits filters never land on
    /// the cached kit. Every other member of its public surface derives from `model`.
    static func ownDecoder(borrowing shared: any TextDecoding, tokenizer: WhisperTokenizer) -> any TextDecoding {
        guard let shared = shared as? TextDecoder else { return shared }
        let own = TextDecoder()
        own.model = shared.model
        own.tokenizer = tokenizer
        own.isModelMultilingual = shared.isModelMultilingual
        return own
    }

    static func resolveInputDeviceID(uid: String?) -> DeviceID? {
        #if os(macOS)
        guard let uid, !uid.isEmpty else { return nil }
        return AudioDevices.deviceID(forUID: uid)
        #else
        return nil
        #endif
    }

    /// Starts the mic stream and loads the model while it captures; returns an `AsyncStream` of
    /// events once the model is in, and what was said meanwhile is decoded first.
    ///
    /// Downloads the model first if it isn't cached yet. The microphone TCC prompt
    /// is shown on first run; if the user denies, the stream closes with `.failed`.
    public func start(
        options: TranscriptionOptions,
        speakerLabeler: (any StreamingSpeakerLabeler)? = nil,
        downloadProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AsyncStream<StreamingEvent> {
        guard loop == nil, !isStarting, modelLease == nil, streamerTask == nil else {
            ParolaLog.fault(.streaming, "start called while a session was already running")
            throw ParolaError.transcriptionFailed("session already started")
        }
        failureAudioURL = nil
        audioCutShort = false

        let modelName = options.model ?? ModelCatalog.fallbackModelID
        if !ModelCatalog.canStream(id: modelName), let variant = ModelCatalog.variant(id: modelName) {
            ParolaLog.notice(.streaming, "engine \(variant.engineID) cannot stream")
            throw ParolaError.unsupportedForEngine(
                "Live transcription runs on Whisper models; \(variant.displayName) can't stream. Pick a Whisper model and try again."
            )
        }
        ParolaLog.info(
            .streaming, "streaming session starting on whisperkit",
            [.model: .safe(ModelToken(modelName))]
        )
        let downloaded: Void? = try await loadingModel { [modelStore] in
            guard !modelStore.isInstalled(modelName) else { return }
            if await EngineRegistry.shared.registeredEngines().isEmpty {
                await ParolaCoreBootstrap.registerBuiltInEngines()
            }
            _ = try await modelStore.download(variant: modelName, progress: downloadProgress)
        }
        guard downloaded != nil else {
            ParolaLog.info(.streaming, "take stopped before capture started")
            return Self.takeEndedBeforeCapture(modelName: modelName, options: options)
        }

        let microphone = microphone(Self.resolveInputDeviceID(uid: deviceUID))
        let persister = persistAudio ? StreamingAudioPersister(sampleRate: Double(WhisperKit.sampleRate)) : nil
        self.loadedModel = modelName
        let stream = launch(
            options: options, speakerLabeler: speakerLabeler, persister: persister
        ) { [modelCache, modelStore] sink, confirmed in
            StreamingRealtimeLoop(
                configuration: .init(wantsConfirmedAudio: speakerLabeler != nil, waitsForModelOnStop: waitsForModelOnStop),
                dependencies: .init(
                    requestPermission: microphone.requestPermission,
                    startCapture: { ingest in
                        try microphone.start { buffer in
                            if ingest(buffer) {
                                persister?.append(buffer)
                            }
                        }
                    },
                    stopCapture: microphone.stop,
                    model: .loading { [weak self] in
                        let lease = try await modelCache.borrow(modelName, store: modelStore)
                        guard let self else {
                            await lease.release()
                            throw CancellationError()
                        }
                        return try await self.decoder(holding: lease, options: options)
                    },
                    tick: { try await Task.sleep(nanoseconds: 100_000_000) }
                ),
                levelMeter: levelMeter,
                clock: clock,
                onPartial: { sink.handlePartial(text: $0) },
                onEnergy: { sink.handleEnergy(last: $0) },
                onConfirmed: { confirmed.yield($0) }
            )
        }
        return try await streamOnceDecoding(stream)
    }

    /// Hands the stream over once decodes can run or the take ends first; a cancel or a failed load throws instead.
    private func streamOnceDecoding(_ stream: AsyncStream<StreamingEvent>) async throws -> AsyncStream<StreamingEvent> {
        guard let loop, let streamerTask else { return stream }
        var decoding = false
        for await _ in loop.decoderReady { decoding = true }
        if Task.isCancelled {
            await cancel()
            throw CancellationError()
        }
        if decoding { return stream }
        switch await streamerTask.value {
        case .cancelled: throw CancellationError()
        case .modelFailed(let error):
            await stopFinished()
            throw error
        case .stopped, .stoppedWithoutModel, .permissionDenied, .failed: return stream
        }
    }

    /// Keeps the borrowed model with the take, so teardown returns it however the take ends.
    private func decoder(
        holding lease: StreamingModelLease, options: TranscriptionOptions
    ) throws -> StreamingRealtimeLoop.Decoder {
        modelLease = lease
        return try makeDecoder(lease, options)
    }

    static func whisperDecoder(
        over lease: StreamingModelLease, options: TranscriptionOptions
    ) throws -> StreamingRealtimeLoop.Decoder {
        let modelName = lease.modelName
        let kit = lease.shared.kit
        guard let tokenizer = kit.tokenizer else {
            ParolaLog.error(
                .streaming, "tokenizer was nil after model load",
                [.model: .safe(ModelToken(modelName))]
            )
            throw ParolaError.transcriptionFailed("WhisperKit tokenizer was nil after model load")
        }

        var decoding = DecodingOptions(
            verbose: options.verbose,
            task: options.task == .translate ? .translate : .transcribe,
            language: options.language,
            detectLanguage: options.language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: options.wordTimestamps
        )
        // Decoding for this session only: logits filters are per-run state and the cached kit's
        // decoder is shared with every other session borrowing the same model.
        var textDecoder = ownDecoder(borrowing: kit.textDecoder, tokenizer: tokenizer)
        textDecoder.logitsFilters = applyInitialPrompt(
            options.initialPrompt,
            to: &decoding,
            tokenizer: tokenizer,
            isModelMultilingual: textDecoder.isModelMultilingual
        )
        nonisolated(unsafe) let transcriber = TranscribeTask(
            currentTimings: TranscriptionTimings(),
            progress: Progress(),
            audioEncoder: kit.audioEncoder,
            featureExtractor: kit.featureExtractor,
            segmentSeeker: kit.segmentSeeker,
            textDecoder: textDecoder,
            tokenizer: tokenizer
        )
        return StreamingRealtimeLoop.Decoder(options: decoding) { samples, decodeOptions, progress in
            // The decoder holds the lease too, so a session dropped mid-take can't let the shared encoder unload under a decode.
            defer { withExtendedLifetime(lease) {} }
            return try await transcriber.run(audioArray: samples, decodeOptions: decodeOptions, callback: progress)
        }
    }

    /// A stop during the download yields nil and a cancel throws; either way capture never starts.
    func loadingModel<Loaded>(_ load: () async throws -> Loaded) async throws -> Loaded? {
        isStarting = true
        pendingEnd = nil
        defer { isStarting = false }
        let loaded = try await load()
        guard let end = Task.isCancelled ? .cancel : pendingEnd else { return loaded }
        switch end {
        case .cancel: throw CancellationError()
        case .stop: return nil
        }
    }

    static func takeEndedBeforeCapture(modelName: String, options: TranscriptionOptions) -> AsyncStream<StreamingEvent> {
        let (stream, continuation) = AsyncStream<StreamingEvent>.makeStream()
        continuation.yield(.finished(Transcript(
            segments: [],
            language: finalLanguage(for: [], options: options),
            modelName: modelName
        )))
        continuation.finish()
        return stream
    }

    /// Runs a take on a loop the caller builds, so tests can drive it without a model.
    func launch(
        options: TranscriptionOptions,
        speakerLabeler: (any StreamingSpeakerLabeler)?,
        persister: StreamingAudioPersister?,
        modelLease: StreamingModelLease? = nil,
        makeLoop: (EventSink, AsyncStream<ConfirmedAudioBatch>.Continuation) -> StreamingRealtimeLoop
    ) -> AsyncStream<StreamingEvent> {
        let (stream, cont) = AsyncStream<StreamingEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let (segStream, segCont) = AsyncStream<ConfirmedAudioBatch>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let loop = makeLoop(EventSink(continuation: cont), segCont)

        self.modelLease = modelLease
        self.persister = persister
        self.optionsForRun = options
        self.loop = loop
        self.startedAt = .now
        self.continuation = cont
        self.segmentContinuation = segCont
        self.speakerLabeler = speakerLabeler

        consumerTask = Task { [weak self] in
            for await batch in segStream {
                await self?.appendConfirmed(batch)
            }
        }

        streamerTask = Task { [weak self] in
            let outcome = await loop.run()
            guard let self else { cont.finish(); return outcome }
            switch outcome {
            case .stopped, .stoppedWithoutModel, .permissionDenied:
                await self.handleStreamerEndedWithoutStop()
            case .cancelled:
                await self.finishStream(failure: nil)
            case .modelFailed:
                await self.finishStream(failure: nil, keepingAudio: true)
            case .failed(let error):
                await self.handleStreamerFailure(error)
            }
            return outcome
        }

        return stream
    }

    /// The loop's intake decides for the file as well: what it takes is written, so the two never drift apart.
    public func setPaused(_ paused: Bool) async {
        loop?.setPaused(paused)
    }

    /// Stops the mic stream, flushes a final transcript, and finishes the stream.
    public func stop() async {
        guard let loop else {
            if isStarting, pendingEnd == nil { pendingEnd = .stop }
            return
        }
        self.loop = nil
        stoppingLoop = loop
        defer { endStopping() }
        await loop.stop()
        // The run task performs the final tail flush after its loop exits; cancelling
        // it here would kill that decode. Confirmed batches from the flush must drain
        // through the consumer before the stream finishes.
        let outcome = await streamerTask?.value
        segmentContinuation?.finish()
        await consumerTask?.value
        var modelRan = true
        switch outcome {
        case .modelFailed?:
            await beforeKeepingFailedAudio?()
            // start() throws the load failure, so the audio waits in recordingAudioURL() rather than in a .finished nobody reads.
            if let kept = await persister?.finish() { failureAudioURL = kept }
            continuation?.finish()
            await teardown()
            return
        case .cancelled?:
            await persister?.discard()
            continuation?.finish()
            await teardown()
            return
        case .stoppedWithoutModel?:
            modelRan = false
        default:
            break
        }

        let recordedURL = await persister?.finish()
        if persister?.droppedAudio == true {
            continuation?.yield(.warning("The recorder fell behind, so the saved audio has gaps."))
        }
        audioCutShort = persister?.writeFailed == true
        let finalTranscript = await finishedTranscript(recordedURL: recordedURL, modelRan: modelRan)
        continuation?.yield(.finished(finalTranscript))
        continuation?.finish()
        await teardown()
    }

    /// A take no model ran on is stamped with no model name, which callers keep as not transcribed rather than as no speech.
    func finishedTranscript(recordedURL: URL?, modelRan: Bool = true) async -> Transcript {
        await Self.finishedTake(
            segments: allConfirmed, options: optionsForRun, modelName: modelRan ? loadedModel ?? "unknown" : "", audioURL: recordedURL
        )
    }

    /// A live take's confirmed segments as they are saved, finished the way a file run is. An
    /// interrupted take goes through this too, so it reads like one that was stopped.
    public static func finishedTake(
        segments: [TranscriptSegment],
        options: TranscriptionOptions?,
        modelName: String,
        audioURL: URL?
    ) async -> Transcript {
        let raw = Transcript(
            segments: segments,
            language: finalLanguage(for: segments, options: options),
            modelName: modelName,
            sourceURL: audioURL,
            durationSeconds: segments.last?.end
        )
        return await TranscriptFinisher.finish(
            raw, engine: .whisperKit, options: options ?? TranscriptionOptions(), audioURL: audioURL
        )
    }

    /// Ends the take without the final decode and deletes its audio; no `.finished` is sent.
    public func cancel() async {
        guard let loop else {
            if let stopping = stoppingLoop {
                await cancelWaitingStop(of: stopping)
            } else if isStarting {
                pendingEnd = .cancel
            }
            return
        }
        self.loop = nil
        await loop.cancel()
        // A decode already in flight would otherwise run to the end before the loop sees the cancel.
        streamerTask?.cancel()
        _ = await streamerTask?.value
        segmentContinuation?.finish()
        consumerTask?.cancel()
        await consumerTask?.value
        await persister?.discard()
        continuation?.finish()
        await teardown()
    }

    /// A stop still waiting for the model ends as a cancel would: its audio goes and no `.finished` is sent.
    private func cancelWaitingStop(of stopping: StreamingRealtimeLoop) async {
        await stopping.cancel()
        streamerTask?.cancel()
        consumerTask?.cancel()
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            if stoppingLoop === stopping {
                stopWaiters.append(waiter)
            } else {
                waiter.resume()
            }
        }
    }

    /// Test seam: runs in a waiting stop just before it finalizes a failed take's audio.
    var beforeKeepingFailedAudio: (@Sendable () async -> Void)?

    func setBeforeKeepingFailedAudio(_ hook: (@Sendable () async -> Void)?) {
        beforeKeepingFailedAudio = hook
    }

    /// A stop that is waiting on the same failed load finalizes the audio; the caller must not see the failure before that.
    private func stopFinished() async {
        guard stoppingLoop != nil else { return }
        await withCheckedContinuation { stopWaiters.append($0) }
    }

    private func endStopping() {
        stoppingLoop = nil
        let waiters = stopWaiters
        stopWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// What a finished take is stamped with: the language the run was pinned to, else what the
    /// text reads as, else "auto" — so a mic take reads like the same audio transcribed from a file.
    static func finalLanguage(for segments: [TranscriptSegment], options: TranscriptionOptions?) -> String {
        options?.language ?? TextLanguageGuess.dominantLanguage(of: segments) ?? "auto"
    }

    public func currentModel() -> String? { loadedModel }

    /// The take's on-disk audio: the in-flight file while recording, or the file a
    /// failure left behind. `nil` when the session doesn't persist audio.
    public func recordingAudioURL() -> URL? {
        persister?.url ?? failureAudioURL
    }

    public func audioWasCutShort() async -> Bool { audioCutShort }

    private func handleStreamerFailure(_ error: Error) async {
        ParolaLog.error(.streaming, "streaming failed", failureFields(error))
        await finishStream(failure: error.localizedDescription)
    }

    private func failureFields(_ error: any Error) -> [LogField: LogValue] {
        var fields: [LogField: LogValue] = [.error: .error(error)]
        if let startedAt { fields[.elapsed] = .duration(startedAt.duration(to: .now)) }
        return fields
    }

    // The loop returns without failing when it can't capture (e.g. denied mic); if stop() didn't drive that return (loop still set), surface a failure so the consumer doesn't wait forever.
    private func handleStreamerEndedWithoutStop() async {
        if loop != nil { ParolaLog.error(.streaming, "streaming loop ended without a stop request") }
        await finishStream(failure: FixedFailureText.microphoneNotStarted)
    }

    private func finishStream(failure: String?, keepingAudio: Bool = false) async {
        guard loop != nil else { return }
        if failure != nil || keepingAudio {
            // Keep the take on disk and publish its URL before the .failed event lands,
            // so a consumer reacting to the event can't read it mid-finish (actor reentrancy).
            failureAudioURL = await persister?.finish()
        } else {
            await persister?.discard()
        }
        if let failure { continuation?.yield(.failed(failure)) }
        segmentContinuation?.finish()
        await consumerTask?.value
        continuation?.finish()
        await teardown()
    }

    private func teardown() async {
        levelMeter.reset()
        continuation = nil
        segmentContinuation = nil
        consumerTask = nil
        streamerTask = nil
        loop = nil
        startedAt = nil
        let lease = modelLease
        modelLease = nil
        persister = nil
        speakerLabeler = nil
        await lease?.release()
    }

    func appendConfirmed(_ batch: ConfirmedAudioBatch) async {
        for seg in batch.segments {
            var mapped = WhisperSegmentMapping.segment(seg, id: nextSegmentID)
            guard !mapped.text.isEmpty else { continue }
            nextSegmentID += 1
            if let labeler = speakerLabeler,
               let label = await labelSpeaker(for: mapped, in: batch, with: labeler) {
                mapped.speaker = label
            }
            allConfirmed.append(mapped)
            continuation?.yield(.confirmed(mapped))
        }
    }

    func labelSpeaker(
        for segment: TranscriptSegment,
        in batch: ConfirmedAudioBatch,
        with labeler: any StreamingSpeakerLabeler
    ) async -> String? {
        guard !batch.audioWindow.isEmpty else { return nil }
        let sampleRate = Double(WhisperKit.sampleRate)
        let batchStart = batch.windowStartSeconds
        let batchEnd = batchStart + Double(batch.audioWindow.count) / sampleRate
        let windowPadding: Double = 0.5
        let windowStartTime = max(batchStart, segment.start - windowPadding)
        let windowEndTime = min(batchEnd, segment.end + windowPadding)
        guard windowEndTime > windowStartTime else { return nil }
        let startIndex = Int((windowStartTime - batchStart) * sampleRate)
        let endIndex = min(batch.audioWindow.count, Int((windowEndTime - batchStart) * sampleRate))
        guard startIndex >= 0, startIndex < endIndex else { return nil }
        return await labeler.labelSpeaker(
            for: segment,
            audioWindow: batch.audioWindow[startIndex..<endIndex],
            windowStartTime: windowStartTime,
            sampleRate: sampleRate
        )
    }
}

// MARK: - Event dedupe

/// Dedupes the loop's partial-text and energy readings into `StreamingEvent`s.
final class EventSink: Sendable {
    private struct State {
        var lastPartial = ""
        var lastVoiceActive: Bool?
    }

    let continuation: AsyncStream<StreamingEvent>.Continuation
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(continuation: AsyncStream<StreamingEvent>.Continuation) {
        self.continuation = continuation
    }

    func handlePartial(text: String) {
        let changed = state.withLock { state -> Bool in
            guard text != state.lastPartial else { return false }
            state.lastPartial = text
            return true
        }
        guard changed, !text.isEmpty else { return }
        continuation.yield(.partial(text: text))
    }

    func handleEnergy(last: Float?) {
        guard let last else { return }
        let voice = last > 0.05
        let changed = state.withLock { state -> Bool in
            guard state.lastVoiceActive != voice else { return false }
            state.lastVoiceActive = voice
            return true
        }
        guard changed else { return }
        continuation.yield(.voiceActivity(active: voice))
    }
}
