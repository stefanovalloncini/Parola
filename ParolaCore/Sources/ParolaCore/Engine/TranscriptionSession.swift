import Foundation

/// Top-level orchestrator. Resolves the right `Transcriber` for the selected model via the
/// shared `EngineRegistry`, manages model loading, and emits transcription events.
///
/// Idle-unload: after `idleTimeout` seconds of inactivity, the active transcriber is released
/// to free memory; the next transcribe call transparently reloads.
public actor TranscriptionSession {
    public let modelStore: ModelStore
    public var idleTimeout: TimeInterval

    private let registry: EngineRegistry
    private let diarizer = DiarizationService()
    private var transcriber: (any Transcriber)?
    private var transcriberEngineID: EngineID?
    private var idleTask: Task<Void, Never>?

    public init(
        modelStore: ModelStore = .shared,
        registry: EngineRegistry = .shared,
        idleTimeout: TimeInterval = 60
    ) {
        self.modelStore = modelStore
        self.registry = registry
        self.idleTimeout = idleTimeout
    }

    /// Transcribes from an AudioSource. Downloads the requested model on demand.
    public func transcribe(
        source: any AudioSource,
        options: TranscriptionOptions,
        downloadProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Transcript {
        await ensureBootstrap()
        let modelName = options.model ?? defaultModelName()
        try Task.checkCancellation()

        let variant = ModelCatalog.variant(id: modelName)
        let engineID = variant?.engineID ?? .whisperKit

        try await validate(options: options, engineID: engineID, variant: variant)

        if !modelStore.isInstalled(modelName) {
            _ = try await modelStore.download(variant: modelName, progress: downloadProgress)
        }
        try Task.checkCancellation()
        cancelIdleTimer()
        let activeTranscriber = try await ensureTranscriber(for: engineID)
        try await activeTranscriber.load(model: modelName)
        try Task.checkCancellation()

        let audioURL = try await source.prepare()
        try Task.checkCancellation()
        var transcript = try await activeTranscriber.transcribe(url: audioURL, options: options)
        if options.diarize {
            try Task.checkCancellation()
            transcript = try await diarizer.diarize(
                transcript: transcript,
                audioURL: audioURL,
                numberOfSpeakers: options.expectedSpeakers
            )
        }
        scheduleIdleUnload()
        return transcript
    }

    public func unloadModel() async {
        cancelIdleTimer()
        if let transcriber {
            await transcriber.unload()
        }
        transcriber = nil
        transcriberEngineID = nil
        await diarizer.unload()
    }

    /// Signals the currently loaded transcriber to abort any in-flight work.
    public func cancelInFlight() async {
        await transcriber?.cancelInFlight()
    }

    public func currentModel() async -> String? {
        await transcriber?.loadedModelName()
    }

    private func validate(
        options: TranscriptionOptions,
        engineID: EngineID,
        variant: ModelVariant?
    ) async throws {
        guard let baseCaps = await registry.capabilities(for: engineID) else {
            throw ParolaError.engineNotRegistered(engineID.rawValue)
        }
        let caps = baseCaps.tightened(by: variant?.languageScope)
        if !caps.supportedLanguages.allows(options.language) && options.language != nil {
            throw ParolaError.unsupportedForEngine(
                "Engine \(engineID) does not support language \"\(options.language ?? "?")\""
            )
        }
        if options.task == .translate, !caps.supportsTranslate {
            throw ParolaError.unsupportedForEngine("Engine \(engineID) does not support translate task")
        }
        if options.diarize, !caps.supportsDiarization {
            throw ParolaError.unsupportedForEngine("Engine \(engineID) does not support diarization")
        }
    }

    private func ensureBootstrap() async {
        let registered = await registry.registeredEngines()
        if registered.isEmpty {
            await ParolaCoreBootstrap.registerBuiltInEngines(registry: registry)
        }
    }

    private func ensureTranscriber(for engineID: EngineID) async throws -> any Transcriber {
        if let existing = transcriber, transcriberEngineID == engineID {
            return existing
        }
        if let old = transcriber {
            await old.unload()
        }
        let fresh = try await registry.transcriber(for: engineID, store: modelStore)
        transcriber = fresh
        transcriberEngineID = engineID
        return fresh
    }

    private func defaultModelName() -> String {
        if let managed = ManagedConfiguration.shared.defaultModel,
           ModelCatalog.variant(id: managed) != nil {
            return managed
        }
        if let recommended = ModelCatalog.all.first(where: { $0.category == .recommended }) {
            return recommended.id
        }
        return "openai_whisper-tiny"
    }

    private func scheduleIdleUnload() {
        cancelIdleTimer()
        let timeout = idleTimeout
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.unloadModel()
        }
    }

    private func cancelIdleTimer() {
        idleTask?.cancel()
        idleTask = nil
    }
}
