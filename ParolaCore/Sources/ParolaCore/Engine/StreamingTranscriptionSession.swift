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
    private var allConfirmed: [TranscriptSegment] = []
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
        self.whisperKit = kit
        self.loadedModel = modelName
        self.optionsForRun = options

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

        let (stream, cont) = AsyncStream<StreamingEvent>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = cont

        let sink = EventSink(continuation: cont)
        sink.onConfirmed = { [weak self] segments in
            guard let self else { return }
            Task { await self.appendConfirmed(segments) }
        }

        let st = AudioStreamTranscriber(
            audioEncoder: kit.audioEncoder,
            featureExtractor: kit.featureExtractor,
            segmentSeeker: kit.segmentSeeker,
            textDecoder: kit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: kit.audioProcessor,
            decodingOptions: decoding,
            stateChangeCallback: { [sink] oldState, newState in
                sink.handle(oldState: oldState, newState: newState)
            }
        )
        self.streamer = st

        Task {
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
        streamer = nil
        whisperKit = nil
    }

    public func currentModel() -> String? { loadedModel }

    private func appendConfirmed(_ segments: [TranscriptionSegment]) {
        for seg in segments {
            let mapped = TranscriptSegment(
                id: allConfirmed.count,
                start: Double(seg.start),
                end: Double(seg.end),
                text: seg.text
            )
            allConfirmed.append(mapped)
            continuation?.yield(.confirmed(mapped))
        }
    }
}

// MARK: - State → event translator

/// Adapts AudioStreamTranscriber's coarse state-diff callback into our finer-grained events.
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

