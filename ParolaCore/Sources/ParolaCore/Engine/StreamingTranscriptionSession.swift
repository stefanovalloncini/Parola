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
        audioWindow: [Float],
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
    public let modelStore: ModelStore
    nonisolated let deviceUID: String?

    private var whisperKit: WhisperKit?
    private var persister: StreamingAudioPersister?
    private var loop: StreamingRealtimeLoop?
    private var continuation: AsyncStream<StreamingEvent>.Continuation?
    private var segmentContinuation: AsyncStream<ConfirmedAudioBatch>.Continuation?
    private var consumerTask: Task<Void, Never>?
    private var streamerTask: Task<Void, Never>?
    private var allConfirmed: [TranscriptSegment] = []
    private var nextSegmentID: Int = 0
    private var loadedModel: String?
    private var optionsForRun: TranscriptionOptions?
    private var speakerLabeler: (any StreamingSpeakerLabeler)?
    nonisolated let persistAudio: Bool

    public init(modelStore: ModelStore = .shared, persistAudio: Bool = false, deviceUID: String? = nil) {
        self.modelStore = modelStore
        self.persistAudio = persistAudio
        self.deviceUID = deviceUID
    }

    static func resolveInputDeviceID(uid: String?) -> DeviceID? {
        #if os(macOS)
        guard let uid, !uid.isEmpty else { return nil }
        return AudioDevices.deviceID(forUID: uid)
        #else
        return nil
        #endif
    }

    /// Loads the model, starts the mic stream, and returns an `AsyncStream` of events.
    ///
    /// Downloads the model first if it isn't cached yet. The microphone TCC prompt
    /// is shown on first run; if the user denies, the stream closes with `.failed`.
    public func start(
        options: TranscriptionOptions,
        speakerLabeler: (any StreamingSpeakerLabeler)? = nil,
        downloadProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AsyncStream<StreamingEvent> {
        guard loop == nil else {
            throw ParolaError.transcriptionFailed("session already started")
        }

        let modelName = options.model ?? ModelCatalog.fallbackModelID
        if let variant = ModelCatalog.variant(id: modelName), variant.engineID != .whisperKit {
            throw ParolaError.unsupportedForEngine(
                "Live transcription runs on Whisper models; \(variant.displayName) can't stream. Pick a Whisper model and try again."
            )
        }
        if !modelStore.isInstalled(modelName) {
            if await EngineRegistry.shared.registeredEngines().isEmpty {
                await ParolaCoreBootstrap.registerBuiltInEngines()
            }
            _ = try await modelStore.download(variant: modelName, progress: downloadProgress)
        }

        let kit = try await StreamingModelCache.shared.borrow(modelName, store: modelStore).kit
        guard let tokenizer = kit.tokenizer else {
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
        if let tokens = promptTokens(options.initialPrompt, tokenizer: kit.tokenizer) {
            decoding.promptTokens = tokens
            decoding.usePrefillPrompt = true
        }

        let (stream, cont) = AsyncStream<StreamingEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let (segStream, segCont) = AsyncStream<ConfirmedAudioBatch>.makeStream(bufferingPolicy: .bufferingNewest(64))

        let sink = EventSink(continuation: cont)

        // Capture must not share the cached kit's AudioProcessor: its AVAudioEngine and sample
        // buffer are per-recording state, and another session could be borrowing the same kit.
        nonisolated(unsafe) let processor = AudioProcessor()
        nonisolated(unsafe) let transcriber = TranscribeTask(
            currentTimings: TranscriptionTimings(),
            progress: Progress(),
            audioProcessor: processor,
            audioEncoder: kit.audioEncoder,
            featureExtractor: kit.featureExtractor,
            segmentSeeker: kit.segmentSeeker,
            textDecoder: kit.textDecoder,
            tokenizer: tokenizer
        )
        let persister = persistAudio ? StreamingAudioPersister(sampleRate: Double(WhisperKit.sampleRate)) : nil
        let inputDeviceID = Self.resolveInputDeviceID(uid: deviceUID)

        let loop = StreamingRealtimeLoop(
            configuration: .init(wantsConfirmedAudio: speakerLabeler != nil),
            decodingOptions: decoding,
            dependencies: .init(
                requestPermission: { await AudioProcessor.requestRecordPermission() },
                startCapture: { ingest in
                    try processor.startRecordingLive(inputDeviceID: inputDeviceID) { buffer in
                        ingest(buffer)
                        persister?.append(buffer)
                        // Runs on the tap thread, serialized with processBuffer's appends, so this purge can't race them.
                        processor.purgeAudioSamples(keepingLast: 0)
                    }
                },
                stopCapture: { processor.stopRecording() },
                transcribe: { samples, decodeOptions, progress in
                    try await transcriber.run(audioArray: samples, decodeOptions: decodeOptions, callback: progress)
                },
                tick: { try await Task.sleep(nanoseconds: 100_000_000) }
            ),
            onPartial: { sink.handlePartial(text: $0) },
            onEnergy: { sink.handleEnergy(last: $0) },
            onConfirmed: { segCont.yield($0) }
        )

        self.whisperKit = kit
        self.persister = persister
        self.loadedModel = modelName
        self.optionsForRun = options
        self.loop = loop
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
            guard let self else { cont.finish(); return }
            switch outcome {
            case .stopped, .permissionDenied:
                await self.handleStreamerEndedWithoutStop()
            case .failed(let error):
                await self.handleStreamerFailure(error)
            }
        }

        return stream
    }

    /// Stops the mic stream, flushes a final transcript, and finishes the stream.
    public func stop() async {
        guard let loop else { return }
        self.loop = nil
        await loop.stop()
        // The run task performs the final tail flush after its loop exits; cancelling
        // it here would kill that decode. Confirmed batches from the flush must drain
        // through the consumer before the stream finishes.
        await streamerTask?.value
        segmentContinuation?.finish()
        await consumerTask?.value

        let finalTranscript = Transcript(
            segments: allConfirmed,
            language: optionsForRun?.language ?? "auto",
            modelName: loadedModel ?? "unknown",
            sourceURL: await persister?.finish(),
            durationSeconds: allConfirmed.last?.end
        )
        continuation?.yield(.finished(finalTranscript))
        continuation?.finish()
        teardown()
    }

    public func currentModel() -> String? { loadedModel }

    private func handleStreamerFailure(_ error: Error) async {
        guard loop != nil else { return }
        continuation?.yield(.failed(error.localizedDescription))
        segmentContinuation?.finish()
        await consumerTask?.value
        continuation?.finish()
        await persister?.discard()
        teardown()
    }

    // The loop returns without failing when it can't capture (e.g. denied mic); if stop() didn't drive that return (loop still set), surface a failure so the consumer doesn't wait forever.
    private func handleStreamerEndedWithoutStop() async {
        guard loop != nil else { return }
        continuation?.yield(.failed("Couldn't start the microphone. Check Microphone access in System Settings › Privacy & Security › Microphone."))
        segmentContinuation?.finish()
        await consumerTask?.value
        continuation?.finish()
        await persister?.discard()
        teardown()
    }

    private func teardown() {
        continuation = nil
        segmentContinuation = nil
        consumerTask = nil
        streamerTask = nil
        loop = nil
        whisperKit = nil
        persister = nil
        speakerLabeler = nil
    }

    private func appendConfirmed(_ batch: ConfirmedAudioBatch) async {
        for seg in batch.segments {
            var mapped = TranscriptSegment(
                id: nextSegmentID,
                start: Double(seg.start),
                end: Double(seg.end),
                text: seg.text
            )
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
        let window = Array(batch.audioWindow[startIndex..<endIndex])
        return await labeler.labelSpeaker(
            for: segment,
            audioWindow: window,
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
