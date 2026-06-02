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
public actor StreamingTranscriptionSession: StreamingTranscriber {
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
    private var speakerLabeler: (any StreamingSpeakerLabeler)?
    private var persistAudio = false

    public init(modelStore: ModelStore = .shared, persistAudio: Bool = false) {
        self.modelStore = modelStore
        self.persistAudio = persistAudio
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

        let sink = EventSink(
            continuation: cont,
            onConfirmed: { segments in segCont.yield(segments) }
        )

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
        self.speakerLabeler = speakerLabeler

        consumerTask = Task { [weak self] in
            for await batch in segStream {
                await self?.appendConfirmed(batch)
            }
        }

        streamerTask = Task { [weak self] in
            do {
                try await st.startStreamTranscription()
                guard let self else { cont.finish(); return }
                await self.handleStreamerEndedWithoutStop()
            } catch {
                guard let self else {
                    cont.yield(.failed(error.localizedDescription))
                    cont.finish()
                    return
                }
                await self.handleStreamerFailure(error)
            }
        }

        return stream
    }

    /// Stops the mic stream, flushes a final transcript, and finishes the stream.
    public func stop() async {
        guard let streamer else { return }
        self.streamer = nil
        await streamer.stopStreamTranscription()
        segmentContinuation?.finish()
        await consumerTask?.value
        streamerTask?.cancel()
        await streamerTask?.value

        let finalTranscript = Transcript(
            segments: allConfirmed,
            language: optionsForRun?.language ?? "auto",
            modelName: loadedModel ?? "unknown",
            sourceURL: persistAudio ? writeCapturedAudio() : nil,
            durationSeconds: allConfirmed.last?.end
        )
        continuation?.yield(.finished(finalTranscript))
        continuation?.finish()
        teardown()
    }

    public func currentModel() -> String? { loadedModel }

    /// Persists the samples WhisperKit accumulated during the live stream to a 16 kHz mono WAV.
    private func writeCapturedAudio() -> URL? {
        guard let kit = whisperKit else { return nil }
        nonisolated(unsafe) let processor = kit.audioProcessor
        let samples = processor.audioSamples
        guard !samples.isEmpty,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(WhisperKit.sampleRate),
                channels: 1,
                interleaved: false
              )
        else { return nil }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-recording-\(UUID().uuidString).wav")
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            let chunkSize = 16_384
            var offset = 0
            while offset < samples.count {
                let count = min(chunkSize, samples.count - offset)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { break }
                buffer.frameLength = AVAudioFrameCount(count)
                samples.withUnsafeBufferPointer { src in
                    buffer.floatChannelData![0].update(from: src.baseAddress!.advanced(by: offset), count: count)
                }
                try file.write(from: buffer)
                offset += count
            }
            return url
        } catch {
            return nil
        }
    }

    private func handleStreamerFailure(_ error: Error) async {
        continuation?.yield(.failed(error.localizedDescription))
        segmentContinuation?.finish()
        await consumerTask?.value
        continuation?.finish()
        teardown()
    }

    // WhisperKit's startStreamTranscription() returns without throwing when it can't capture (e.g. denied mic); if stop() didn't drive that return (streamer still set), surface a failure so the consumer doesn't wait forever.
    private func handleStreamerEndedWithoutStop() async {
        guard streamer != nil else { return }
        continuation?.yield(.failed("Couldn't start the microphone. Check Microphone access in System Settings › Privacy & Security › Microphone."))
        segmentContinuation?.finish()
        await consumerTask?.value
        continuation?.finish()
        teardown()
    }

    private func teardown() {
        continuation = nil
        segmentContinuation = nil
        consumerTask = nil
        streamerTask = nil
        streamer = nil
        whisperKit = nil
        speakerLabeler = nil
    }

    private func appendConfirmed(_ segments: [TranscriptionSegment]) async {
        for seg in segments {
            var mapped = TranscriptSegment(
                id: nextSegmentID,
                start: Double(seg.start),
                end: Double(seg.end),
                text: seg.text
            )
            nextSegmentID += 1
            if let labeler = speakerLabeler,
               let label = await labelSpeaker(for: mapped, with: labeler) {
                mapped.speaker = label
            }
            allConfirmed.append(mapped)
            continuation?.yield(.confirmed(mapped))
        }
    }

    private func labelSpeaker(
        for segment: TranscriptSegment,
        with labeler: any StreamingSpeakerLabeler
    ) async -> String? {
        guard let kit = whisperKit else { return nil }
        nonisolated(unsafe) let processor = kit.audioProcessor
        let allSamples = processor.audioSamples
        let sampleRate = Double(WhisperKit.sampleRate)
        let totalSeconds = Double(allSamples.count) / sampleRate
        let segmentStart = max(0, segment.start)
        let segmentEnd = max(segmentStart, segment.end)
        let windowPadding: Double = 0.5
        let windowStartTime = max(0, segmentStart - windowPadding)
        let windowEndTime = min(totalSeconds, segmentEnd + windowPadding)
        guard windowEndTime > windowStartTime else { return nil }
        let startIndex = Int(windowStartTime * sampleRate)
        let endIndex = min(allSamples.count, Int(windowEndTime * sampleRate))
        guard startIndex < endIndex else { return nil }
        let window = Array(allSamples[startIndex..<endIndex])
        return await labeler.labelSpeaker(
            for: segment,
            audioWindow: window,
            windowStartTime: windowStartTime,
            sampleRate: sampleRate
        )
    }
}

// MARK: - State → event translator

/// Adapts AudioStreamTranscriber's coarse state-diff callback into our finer-grained events.
final class EventSink: Sendable {
    private struct State {
        var lastPartial = ""
        var lastVoiceActive: Bool?
    }

    let continuation: AsyncStream<StreamingEvent>.Continuation
    let onConfirmed: @Sendable ([TranscriptionSegment]) -> Void
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        continuation: AsyncStream<StreamingEvent>.Continuation,
        onConfirmed: @escaping @Sendable ([TranscriptionSegment]) -> Void
    ) {
        self.continuation = continuation
        self.onConfirmed = onConfirmed
    }

    func handle(
        oldState: AudioStreamTranscriber.State,
        newState: AudioStreamTranscriber.State
    ) {
        let oldCount = oldState.confirmedSegments.count
        let newCount = newState.confirmedSegments.count
        if newCount > oldCount {
            onConfirmed(Array(newState.confirmedSegments.suffix(newCount - oldCount)))
        }
        handlePartial(text: Self.partial(from: newState))
        handleEnergy(last: newState.bufferEnergy.last)
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

    private static func partial(from state: AudioStreamTranscriber.State) -> String {
        if !state.unconfirmedSegments.isEmpty {
            return state.unconfirmedSegments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        }
        return state.currentText.trimmingCharacters(in: .whitespaces)
    }
}
