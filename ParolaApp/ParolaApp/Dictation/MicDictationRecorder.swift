import Foundation
import ParolaCore
import ParolaDictation

actor MicDictationRecorder: DictationRecorder {
    private let model: String?
    private let defaultLanguage: String?
    private var effectiveLanguage: String?
    private let initialPrompt: String?
    private let deviceUID: String?
    private let streamingEnabled: Bool
    private let workflowResolver: (@Sendable () async -> DictationWorkflow?)?
    private let downloadProgress: (@Sendable (Double) -> Void)?
    private var partialContinuations: [UUID: AsyncStream<String>.Continuation] = [:]

    private var fallbackSource: (any LiveAudioSource)?
    private let fallbackSession: TranscriptionSession
    private let clock: any Clock<Duration>
    private let makeStreamingSession: @Sendable () -> any StreamingTranscriber

    private var streamingSession: (any StreamingTranscriber)?
    private var streamingConsumer: Task<Void, Never>?
    private var streamingSegments: [TranscriptSegment] = []
    private var streamingPartial: String = ""
    private var streamingFailure: String?

    init(
        model: String?,
        language: String?,
        initialPrompt: String? = nil,
        deviceUID: String? = nil,
        streamingEnabled: Bool = true,
        session: TranscriptionSession? = nil,
        workflowResolver: (@Sendable () async -> DictationWorkflow?)? = nil,
        downloadProgress: (@Sendable (Double) -> Void)? = nil,
        clock: any Clock<Duration> = ContinuousClock(),
        makeStreamingSession: (@Sendable () -> any StreamingTranscriber)? = nil
    ) {
        self.model = model
        self.defaultLanguage = language
        self.effectiveLanguage = language
        self.initialPrompt = initialPrompt
        self.deviceUID = deviceUID
        self.streamingEnabled = streamingEnabled
        self.fallbackSession = session ?? TranscriptionSession()
        self.workflowResolver = workflowResolver
        self.downloadProgress = downloadProgress
        self.clock = clock
        self.makeStreamingSession = makeStreamingSession ?? { [clock] in
            StreamingTranscriberFactory.make(clock: clock, deviceUID: deviceUID)
        }
    }

    private func resolveLanguageOverride() async {
        guard let resolver = workflowResolver else {
            effectiveLanguage = defaultLanguage
            return
        }
        let workflow = await resolver()
        if let override = workflow?.language, !override.isEmpty {
            effectiveLanguage = override
        } else {
            effectiveLanguage = defaultLanguage
        }
    }

    func start() async throws {
        await resolveLanguageOverride()
        if useStreaming {
            try await startStreaming()
        } else {
            try await startFallback()
        }
    }

    func stopAndTranscribe() async throws -> String {
        await resolveLanguageOverride()
        if streamingSession != nil {
            return try await stopStreaming()
        }
        return try await stopFallback()
    }

    func stopAndDiscard() async {
        if let session = streamingSession {
            await session.cancel()
            await streamingConsumer?.value
            streamingConsumer = nil
            streamingSession = nil
            streamingSegments = []
            streamingPartial = ""
            streamingFailure = nil
            return
        }
        guard let source = fallbackSource else { return }
        fallbackSource = nil
        // prepare() is the only way to stop capture; the finalized take is thrown away
        // unread, so no model load or transcription happens on this path.
        if let url = try? await source.prepare() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func levelMeter() -> LevelMeter? {
        streamingSession?.levelMeter ?? fallbackSource?.levelMeter
    }

    func partials() -> AsyncStream<String> {
        AsyncStream { continuation in
            let id = UUID()
            partialContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removePartialContinuation(id) }
            }
        }
    }

    private var useStreaming: Bool {
        guard streamingEnabled, let model else { return false }
        return ModelCatalog.canStream(id: model)
    }

    func transcriptionOptions() -> TranscriptionOptions {
        TranscriptionOptions(
            model: model,
            language: effectiveLanguage,
            task: .transcribe,
            initialPrompt: initialPrompt
        )
    }

    private func startStreaming() async throws {
        let session = makeStreamingSession()
        streamingSegments = []
        streamingPartial = ""
        streamingFailure = nil

        let events = try await session.start(options: transcriptionOptions(), speakerLabeler: nil, downloadProgress: downloadProgress)
        streamingSession = session

        streamingConsumer = Task { [weak self] in
            for await event in events {
                await self?.handleStreaming(event)
            }
        }
    }

    private func stopStreaming() async throws -> String {
        guard let session = streamingSession else { return "" }
        await session.stop()
        await streamingConsumer?.value
        streamingConsumer = nil
        streamingSession = nil
        let failure = streamingFailure
        streamingFailure = nil
        let text = combinedText().trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep whatever was confirmed before a mid-stream failure; throw only when it ate everything.
        if let failure, text.isEmpty {
            throw ParolaError.transcriptionFailed(failure)
        }
        return text
    }

    private func handleStreaming(_ event: StreamingEvent) async {
        switch event {
        case .partial(let text):
            streamingPartial = text
            broadcastPartial(combinedText())
        case .confirmed(let segment):
            streamingSegments.append(segment)
            streamingPartial = ""
            broadcastPartial(combinedText())
        case .failed(let message):
            streamingFailure = message
        case .voiceActivity, .warning, .finished:
            break
        }
    }

    private func combinedText() -> String {
        let confirmed = streamingSegments.map(\.text).joined(separator: " ")
        if streamingPartial.isEmpty { return confirmed }
        if confirmed.isEmpty { return streamingPartial }
        return confirmed + " " + streamingPartial
    }

    private func startFallback() async throws {
        guard fallbackSource == nil else { return }
        let mic = await LiveAudioSourceFactory.makeMicrophone(deviceUID: deviceUID, clock: clock)
        try await mic.start()
        fallbackSource = mic
    }

    private func stopFallback() async throws -> String {
        guard let source = fallbackSource else { return "" }
        self.fallbackSource = nil
        let url = try await source.prepare()
        let transcript = try await fallbackSession.transcribe(
            source: FileAudioSource(url: url),
            options: transcriptionOptions(),
            downloadProgress: downloadProgress
        )
        return transcript.text
    }

    private func removePartialContinuation(_ id: UUID) {
        partialContinuations.removeValue(forKey: id)
    }

    private func broadcastPartial(_ text: String) {
        for continuation in partialContinuations.values {
            continuation.yield(text)
        }
    }
}
