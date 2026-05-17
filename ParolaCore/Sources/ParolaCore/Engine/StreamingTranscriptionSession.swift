import Foundation
@preconcurrency import WhisperKit

/// Drives real-time microphone transcription via WhisperKit's `AudioStreamTranscriber`.
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
public actor StreamingTranscriptionSession {
    public let modelStore: ModelStore

    private var whisperKit: WhisperKit?
    private var streamer: AudioStreamTranscriber?
    private var continuation: AsyncStream<StreamingEvent>.Continuation?
    private var segmentContinuation: AsyncStream<[TranscriptionSegment]>.Continuation?
    private var consumerTask: Task<Void, Never>?
    private var streamerTask: Task<Void, Never>?
    private var allConfirmed: [TranscriptSegment] = []
    private var nextSegmentID: Int = 0
    private var loadedModel: String?
    private var optionsForRun: TranscriptionOptions?

    public init(modelStore: ModelStore = .shared) {
        self.modelStore = modelStore
    }

    /// Loads the model, starts the mic stream, and returns an `AsyncStream` of events.
    ///
    /// Downloads the model first if it isn't cached yet. The microphone TCC prompt
    /// is shown on first run; if the user denies, the stream closes with `.failed`.
    public func start(
        options: TranscriptionOptions,
        downloadProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AsyncStream<StreamingEvent> {
        guard streamer == nil else {
            throw ParolaError.transcriptionFailed("session already started")
        }

        let modelName = options.model ?? "openai_whisper-tiny"
        if !modelStore.isInstalled(modelName) {
            _ = try await modelStore.download(variant: modelName, progress: downloadProgress)
        }

        let kit = try await WhisperKit(
            model: modelName,
            downloadBase: modelStore.directory,
            modelFolder: modelStore.installedURL(for: modelName).path,
            verbose: false,
            logLevel: .none,
            prewarm: false,
            load: true,
            download: false
        )
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
        let (segStream, segCont) = AsyncStream<[TranscriptionSegment]>.makeStream(bufferingPolicy: .bufferingNewest(64))

        let sink = EventSink(continuation: cont)
        sink.onConfirmed = { segments in segCont.yield(segments) }

        // AudioStreamTranscriber owns its own internal queue and is held in actor-isolated
        // `streamer`, so these non-Sendable WhisperKit references never escape.
        nonisolated(unsafe) let streamerAudioEncoder = kit.audioEncoder
        nonisolated(unsafe) let streamerFeatureExtractor = kit.featureExtractor
        nonisolated(unsafe) let streamerSegmentSeeker = kit.segmentSeeker
        nonisolated(unsafe) let streamerTextDecoder = kit.textDecoder
        nonisolated(unsafe) let streamerTokenizer = tokenizer
        nonisolated(unsafe) let streamerAudioProcessor = kit.audioProcessor

        let st = AudioStreamTranscriber(
            audioEncoder: streamerAudioEncoder,
            featureExtractor: streamerFeatureExtractor,
            segmentSeeker: streamerSegmentSeeker,
            textDecoder: streamerTextDecoder,
            tokenizer: streamerTokenizer,
            audioProcessor: streamerAudioProcessor,
            decodingOptions: decoding,
            stateChangeCallback: { [sink] oldState, newState in
                sink.handle(oldState: oldState, newState: newState)
            }
        )

        self.whisperKit = kit
        self.loadedModel = modelName
        self.optionsForRun = options
        self.streamer = st
        self.continuation = cont
        self.segmentContinuation = segCont

        consumerTask = Task { [weak self] in
            for await batch in segStream {
                await self?.appendConfirmed(batch)
            }
        }

        streamerTask = Task {
            do {
                try await st.startStreamTranscription()
            } catch {
                cont.yield(.failed("stream start failed: \(error.localizedDescription)"))
                cont.finish()
            }
        }

        return stream
    }

    /// Stops the mic stream, flushes a final transcript, and finishes the stream.
    public func stop() async {
        await streamer?.stopStreamTranscription()
        segmentContinuation?.finish()
        await consumerTask?.value
        streamerTask?.cancel()
        await streamerTask?.value

        let finalTranscript = Transcript(
            segments: allConfirmed,
            language: optionsForRun?.language ?? "auto",
            modelName: loadedModel ?? "unknown",
            sourceURL: nil,
            durationSeconds: allConfirmed.last?.end
        )
        continuation?.yield(.finished(finalTranscript))
        continuation?.finish()
        continuation = nil
        segmentContinuation = nil
        consumerTask = nil
        streamerTask = nil
        streamer = nil
        whisperKit = nil
    }

    public func currentModel() -> String? { loadedModel }

    private func appendConfirmed(_ segments: [TranscriptionSegment]) {
        for seg in segments {
            let mapped = TranscriptSegment(
                id: nextSegmentID,
                start: Double(seg.start),
                end: Double(seg.end),
                text: seg.text
            )
            nextSegmentID += 1
            allConfirmed.append(mapped)
            continuation?.yield(.confirmed(mapped))
        }
    }
}

// MARK: - State → event translator

/// Adapts AudioStreamTranscriber's coarse state-diff callback into our finer-grained events.
///
/// Unchecked Sendable: WhisperKit's `AudioStreamTranscriber` delivers state callbacks serially
/// from its own internal queue, so the mutable state inside this sink is touched by one thread
/// at a time even without explicit locking.
private final class EventSink: @unchecked Sendable {
    let continuation: AsyncStream<StreamingEvent>.Continuation
    var onConfirmed: (@Sendable ([TranscriptionSegment]) -> Void)?
    private var lastPartial: String = ""
    private var lastVoiceActive: Bool? = nil

    init(continuation: AsyncStream<StreamingEvent>.Continuation) {
        self.continuation = continuation
    }

    func handle(
        oldState: AudioStreamTranscriber.State,
        newState: AudioStreamTranscriber.State
    ) {
        emitNewlyConfirmedSegments(oldState: oldState, newState: newState)
        emitPartial(from: newState)
        emitVoiceActivity(from: newState)
    }

    private func emitNewlyConfirmedSegments(
        oldState: AudioStreamTranscriber.State,
        newState: AudioStreamTranscriber.State
    ) {
        let oldCount = oldState.confirmedSegments.count
        let newCount = newState.confirmedSegments.count
        guard newCount > oldCount else { return }
        onConfirmed?(Array(newState.confirmedSegments.suffix(newCount - oldCount)))
    }

    private func emitPartial(from state: AudioStreamTranscriber.State) {
        let partial = Self.partial(from: state)
        guard partial != lastPartial else { return }
        lastPartial = partial
        if !partial.isEmpty {
            continuation.yield(.partial(text: partial))
        }
    }

    private func emitVoiceActivity(from state: AudioStreamTranscriber.State) {
        let voice = state.bufferEnergy.last.map { $0 > 0.05 } ?? false
        guard lastVoiceActive != voice else { return }
        lastVoiceActive = voice
        continuation.yield(.voiceActivity(active: voice))
    }

    private static func partial(from state: AudioStreamTranscriber.State) -> String {
        if !state.unconfirmedSegments.isEmpty {
            return state.unconfirmedSegments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        }
        return state.currentText.trimmingCharacters(in: .whitespaces)
    }
}
