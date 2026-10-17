import Foundation
import ParolaCore
import ParolaDictation

actor MicDictationRecorder: DictationRecorder {
    struct Settings: Sendable {
        var model: String?
        var language: String?
        var initialPrompt: String?
        var deviceUID: String?
        var streamingEnabled: Bool
        var workflows: [String: [DictationWorkflow]]
    }

    private let defaults: Settings
    private let workflowResolver: (@Sendable ([String: [DictationWorkflow]]) async -> DictationWorkflow?)?
    private let downloadProgress: (@Sendable (Double) -> Void)?
    private var partialContinuations: [UUID: AsyncStream<String>.Continuation] = [:]

    private let fallbackSession: TranscriptionSession
    private let clock: any Clock<Duration>
    private let makeStreamingSession: (@Sendable (_ deviceUID: String?, _ serializer: DecodeSerializer) -> any StreamingTranscriber)?
    private let decodeSerializer = DecodeSerializer()
    private let warmFallbackModel: @Sendable (String) async -> Void
    private let onRunEnded: (@Sendable () -> Void)?

    private var capturing: (id: UUID, take: MicTake)?
    private var newestReleased: UUID?

    init(
        model: String?,
        language: String?,
        initialPrompt: String? = nil,
        deviceUID: String? = nil,
        streamingEnabled: Bool = true,
        workflows: [String: [DictationWorkflow]] = [:],
        session: TranscriptionSession? = nil,
        onRunEnded: (@Sendable () -> Void)? = nil,
        workflowResolver: (@Sendable ([String: [DictationWorkflow]]) async -> DictationWorkflow?)? = nil,
        downloadProgress: (@Sendable (Double) -> Void)? = nil,
        clock: any Clock<Duration> = ContinuousClock(),
        makeStreamingSession: (@Sendable () -> any StreamingTranscriber)? = nil,
        makeSerializedSession: (@Sendable (String?, DecodeSerializer) -> any StreamingTranscriber)? = nil,
        warmFallbackModel: (@Sendable (String) async -> Void)? = nil
    ) {
        defaults = Settings(
            model: model, language: language, initialPrompt: initialPrompt, deviceUID: deviceUID,
            streamingEnabled: streamingEnabled, workflows: workflows
        )
        let fallbackSession = session ?? TranscriptionSession()
        self.fallbackSession = fallbackSession
        self.onRunEnded = onRunEnded
        self.warmFallbackModel = warmFallbackModel ?? { await fallbackSession.prewarm(modelName: $0) }
        self.workflowResolver = workflowResolver
        self.downloadProgress = downloadProgress
        self.clock = clock
        if let makeSerializedSession {
            self.makeStreamingSession = makeSerializedSession
        } else if let makeStreamingSession {
            self.makeStreamingSession = { @Sendable _, _ in makeStreamingSession() }
        } else {
            self.makeStreamingSession = nil
        }
    }

    func start() async throws {
        try await start(settings: defaults)
    }

    func start(configuration: DictationPipelineConfiguration) async throws {
        try await start(settings: Settings(
            model: configuration.modelName, language: configuration.language,
            initialPrompt: configuration.initialPrompt, deviceUID: configuration.deviceUID,
            streamingEnabled: configuration.streamingEnabled, workflows: configuration.workflows
        ))
    }

    private func start(settings: Settings) async throws {
        guard capturing == nil else {
            ParolaLog.fault(.dictation, "dictation recorder asked to start while a take is capturing")
            throw ParolaError.transcriptionFailed("A take is already recording.")
        }
        let id = UUID()
        let take = MicTake(
            settings: settings,
            workflowResolver: workflowResolver,
            downloadProgress: downloadProgress,
            fallbackSession: fallbackSession,
            clock: clock,
            makeStreamingSession: makeStreamingSession,
            decodeSerializer: decodeSerializer,
            warmFallbackModel: warmFallbackModel,
            onRunEnded: onRunEnded,
            onPartial: { [weak self] text in await self?.broadcastPartial(text, from: id) }
        )
        capturing = (id, take)
        do {
            try await take.begin()
        } catch {
            if capturing?.id == id { capturing = nil }
            throw presented(error)
        }
    }

    private func presented(_ error: any Error) -> any Error {
        if !(error is CancellationError) {
            ParolaLog.error(.dictation, "dictation recorder failed", [.error: .error(error)])
        }
        return FailureText.presented(error)
    }

    func stopCapture() async throws -> DictationTake {
        guard let (id, take) = capturing else { return DictationTake(finalize: { "" }) }
        capturing = nil
        newestReleased = id
        do {
            let finalize = try await take.stopCapture()
            return DictationTake(
                finalize: { do { return try await finalize() } catch { throw await self.presented(error) } },
                discard: { await take.discard() }
            )
        } catch {
            throw presented(error)
        }
    }

    func stopAndTranscribe() async throws -> String {
        try await stopCapture().finalize()
    }

    func stopAndDiscard() async {
        guard let (_, take) = capturing else { return }
        capturing = nil
        await take.discard()
    }

    func levelMeter() async -> LevelMeter? {
        await capturing?.take.levelMeter()
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

    func transcriptionOptions() -> TranscriptionOptions {
        MicTake.options(for: defaults, language: defaults.language)
    }

    /// Dictation audio is scratch: it goes once read or given up on. Only a file named for dictation, never a test fixture.
    static func discardScratch(_ url: URL) {
        guard url.lastPathComponent.hasPrefix(RecordingScratch.dictationPrefix + "-") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func removePartialContinuation(_ id: UUID) {
        partialContinuations.removeValue(forKey: id)
    }

    private func broadcastPartial(_ text: String, from id: UUID) {
        guard capturing?.id == id || (capturing == nil && newestReleased == id) else { return }
        for continuation in partialContinuations.values {
            continuation.yield(text)
        }
    }
}

private actor MicTake {
    private let settings: MicDictationRecorder.Settings
    private let workflowResolver: (@Sendable ([String: [DictationWorkflow]]) async -> DictationWorkflow?)?
    private let downloadProgress: (@Sendable (Double) -> Void)?
    private let fallbackSession: TranscriptionSession
    private let clock: any Clock<Duration>
    private let makeStreamingSession: (@Sendable (String?, DecodeSerializer) -> any StreamingTranscriber)?
    private let decodeSerializer: DecodeSerializer
    private let warmFallbackModel: @Sendable (String) async -> Void
    private let onRunEnded: (@Sendable () -> Void)?
    private let onPartial: @Sendable (String) async -> Void

    private var effectiveLanguage: String?
    private var fallbackSource: (any LiveAudioSource)?
    private var stoppedFallbackURL: URL?
    private var streamingSession: (any StreamingTranscriber)?
    private var streamingConsumer: Task<Void, Never>?
    private var streamingSegments: [TranscriptSegment] = []
    private var streamingPartial = ""
    private var streamingFailure: String?
    private var isStarting = false
    private var discardRequested = false

    init(
        settings: MicDictationRecorder.Settings,
        workflowResolver: (@Sendable ([String: [DictationWorkflow]]) async -> DictationWorkflow?)?,
        downloadProgress: (@Sendable (Double) -> Void)?,
        fallbackSession: TranscriptionSession,
        clock: any Clock<Duration>,
        makeStreamingSession: (@Sendable (String?, DecodeSerializer) -> any StreamingTranscriber)?,
        decodeSerializer: DecodeSerializer,
        warmFallbackModel: @escaping @Sendable (String) async -> Void,
        onRunEnded: (@Sendable () -> Void)?,
        onPartial: @escaping @Sendable (String) async -> Void
    ) {
        self.settings = settings
        self.effectiveLanguage = settings.language
        self.workflowResolver = workflowResolver
        self.downloadProgress = downloadProgress
        self.fallbackSession = fallbackSession
        self.clock = clock
        self.makeStreamingSession = makeStreamingSession
        self.decodeSerializer = decodeSerializer
        self.warmFallbackModel = warmFallbackModel
        self.onRunEnded = onRunEnded
        self.onPartial = onPartial
    }

    static func options(for settings: MicDictationRecorder.Settings, language: String?) -> TranscriptionOptions {
        TranscriptionOptions(
            model: settings.model,
            language: language,
            task: .transcribe,
            initialPrompt: settings.initialPrompt
        )
    }

    private var useStreaming: Bool {
        guard settings.streamingEnabled, let model = settings.model else { return false }
        return ModelCatalog.canStream(id: model)
    }

    private func options() -> TranscriptionOptions {
        Self.options(for: settings, language: effectiveLanguage)
    }

    private func resolveLanguageOverride() async {
        guard let resolver = workflowResolver else {
            effectiveLanguage = settings.language
            return
        }
        let workflow = await resolver(settings.workflows)
        if let override = workflow?.language, !override.isEmpty {
            effectiveLanguage = override
        } else {
            effectiveLanguage = settings.language
        }
    }

    func begin() async throws {
        isStarting = true
        defer { isStarting = false }
        await resolveLanguageOverride()
        if discardRequested { throw CancellationError() }
        if useStreaming {
            try await startStreaming()
        } else {
            try await startFallback()
        }
    }

    func levelMeter() -> LevelMeter? {
        streamingSession?.levelMeter ?? fallbackSource?.levelMeter
    }

    func discard() async {
        // Before any session or file exists, the start under way sees this and never opens the mic.
        if isStarting, streamingSession == nil, fallbackSource == nil { discardRequested = true }
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
        if let url = stoppedFallbackURL {
            stoppedFallbackURL = nil
            MicDictationRecorder.discardScratch(url)
            return
        }
        guard let source = fallbackSource else { return }
        fallbackSource = nil
        // prepare() is the only way to stop capture; the finalized take is thrown away
        // unread, so no model load or transcription happens on this path.
        do {
            MicDictationRecorder.discardScratch(try await source.prepare())
        } catch let cut as CaptureInterrupted {
            MicDictationRecorder.discardScratch(cut.url)
        } catch {}
    }

    func stopCapture() async throws -> @Sendable () async throws -> String {
        if let session = streamingSession {
            await session.stopCapturing()
            return { try await self.finishStreaming(session) }
        }
        guard let source = fallbackSource else { return { "" } }
        fallbackSource = nil
        let url: URL
        do {
            url = try await source.prepare()
        } catch let cut as CaptureInterrupted {
            MicDictationRecorder.discardScratch(cut.url)
            throw cut
        }
        stoppedFallbackURL = url
        return { try await self.transcribeFallback(url) }
    }

    private func startStreaming() async throws {
        let session = makeStreamingSession?(settings.deviceUID, decodeSerializer)
            ?? StreamingTranscriberFactory.make(clock: clock, deviceUID: settings.deviceUID, decodeSerializer: decodeSerializer)
        streamingSegments = []
        streamingPartial = ""
        streamingFailure = nil

        streamingSession = session

        let events: AsyncStream<StreamingEvent>
        do {
            events = try await session.start(options: options(), speakerLabeler: nil, downloadProgress: downloadProgress)
        } catch {
            streamingSession = nil
            throw error
        }
        // A discard that landed during the load already cancelled the session.
        guard streamingSession != nil else { throw CancellationError() }

        streamingConsumer = Task { [weak self] in
            for await event in events {
                await self?.handleStreaming(event)
            }
        }
    }

    private func finishStreaming(_ session: any StreamingTranscriber) async throws -> String {
        guard streamingSession != nil else { return "" }
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
            await onPartial(combinedText())
        case .confirmed(let segment):
            streamingSegments.append(segment)
            streamingPartial = ""
            await onPartial(combinedText())
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
        if let model = settings.model {
            let warm = warmFallbackModel
            Task { await warm(model) }
        }
        let mic = await LiveAudioSourceFactory.makeMicrophone(
            deviceUID: settings.deviceUID, clock: clock, filePrefix: RecordingScratch.dictationPrefix
        )
        if discardRequested { throw CancellationError() }
        try await mic.start()
        if discardRequested {
            await mic.cancel()
            throw CancellationError()
        }
        fallbackSource = mic
    }

    private func transcribeFallback(_ url: URL) async throws -> String {
        stoppedFallbackURL = nil
        defer {
            MicDictationRecorder.discardScratch(url)
            onRunEnded?()
        }
        let transcript = try await fallbackSession.transcribe(
            source: FileAudioSource(url: url),
            options: options(),
            downloadProgress: downloadProgress
        )
        return transcript.text
    }
}
