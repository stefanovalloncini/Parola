import Foundation

/// Top-level orchestrator. Resolves the right `Transcriber` for the selected model via the
/// shared `EngineRegistry`, manages model loading, and emits transcription events.
///
/// Idle-unload: the diarizer is released after a short fixed idle; the active transcriber
/// stays warm until `idleTimeout` seconds of inactivity or critical memory pressure, then
/// the next transcribe call transparently reloads.
public actor TranscriptionSession {
    public let modelStore: ModelStore
    public var idleTimeout: TimeInterval

    private let registry: EngineRegistry
    private let managedConfiguration: ManagedConfiguration
    let diarizer = DiarizationService()
    private let diarizerIdleTimeout: TimeInterval = 60
    private let clock: any Clock<Duration>
    private var transcriber: (any Transcriber)?
    private var transcriberEngineID: EngineID?
    private var idleTask: Task<Void, Never>?
    private var diarizerIdleTask: Task<Void, Never>?
    private var idleEpoch: Int = 0
    private var pressureSource: (any DispatchSourceMemoryPressure)?
    private var transcribeRunning = false
    private var transcribeWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        modelStore: ModelStore = .shared,
        registry: EngineRegistry = .shared,
        idleTimeout: TimeInterval = 600,
        clock: any Clock<Duration> = ContinuousClock(),
        managedConfiguration: ManagedConfiguration = .shared
    ) {
        self.modelStore = modelStore
        self.registry = registry
        self.idleTimeout = idleTimeout
        self.clock = clock
        self.managedConfiguration = managedConfiguration
    }

    /// Transcribes from an AudioSource. Downloads the requested model on demand.
    public func transcribe(
        source: any AudioSource,
        options: TranscriptionOptions,
        downloadProgress: (@Sendable (Double) -> Void)? = nil,
        partialHandler: (@Sendable (String) -> Void)? = nil,
        progressHandler: (@Sendable (Double) -> Void)? = nil,
        stageHandler: (@Sendable (TranscribeStage) -> Void)? = nil
    ) async throws -> Transcript {
        // Whole runs are serialized: interleaved calls would swap each other's transcriber out
        // via ensureTranscriber's unload and cross-wire the partial/progress callbacks.
        try await acquireTranscribeSlot()
        defer { releaseTranscribeSlot() }

        installPressureSourceIfNeeded()
        await ensureBootstrap()
        var options = options
        if managedConfiguration.requireEnglishOnly, options.language == nil {
            options.language = "en"
        }
        let modelName = options.model ?? defaultModelName(for: options)
        try Task.checkCancellation()

        let variant = ModelCatalog.variant(id: modelName)
        let engineID = variant?.engineID ?? .whisperKit

        try await validate(options: options, engineID: engineID, variant: variant)

        if !modelStore.isInstalled(modelName) {
            _ = try await modelStore.download(
                variant: modelName, progress: downloadProgress, registry: registry
            )
        }
        try Task.checkCancellation()
        cancelIdleTimer()
        // Rearm on every exit: a throw below (incl. cancellation) would otherwise leave the
        // loaded model resident with no idle timer until the next successful run.
        defer { scheduleIdleUnload() }
        let activeTranscriber = try await ensureTranscriber(for: engineID)
        try await activeTranscriber.load(model: modelName)
        try Task.checkCancellation()

        let audioURL = try await source.prepare()
        try Task.checkCancellation()
        // Abort engine work when the caller cancels: a hung engine (e.g. a stalled finalize)
        // would otherwise hold the transcribe slot and block every queued run until relaunch.
        var transcript = try await withTaskCancellationHandler {
            try await activeTranscriber.transcribe(
                url: audioURL,
                options: options,
                handlers: TranscribeHandlers(
                    onPartial: partialHandler,
                    onProgress: progressHandler,
                    onStage: stageHandler
                )
            )
        } onCancel: {
            Task { await self.cancelInFlight() }
        }
        transcript = TranscriptCleanup.apply(to: transcript)
        if options.diarize {
            try Task.checkCancellation()
            transcript = try await diarizer.diarize(
                transcript: transcript,
                audioURL: audioURL,
                numberOfSpeakers: options.expectedSpeakers
            )
        }
        return transcript
    }

    private func acquireTranscribeSlot() async throws {
        while transcribeRunning {
            try Task.checkCancellation()
            // On cancel, wake every waiter: the cancelled one re-loops into the check above
            // and throws; the rest re-queue.
            await withTaskCancellationHandler {
                await withCheckedContinuation { transcribeWaiters.append($0) }
            } onCancel: {
                Task { await self.wakeTranscribeWaiters() }
            }
        }
        transcribeRunning = true
    }

    private func tryAcquireTranscribeSlot() -> Bool {
        guard !transcribeRunning, transcribeWaiters.isEmpty else { return false }
        transcribeRunning = true
        return true
    }

    private func releaseTranscribeSlot() {
        transcribeRunning = false
        wakeTranscribeWaiters()
    }

    private func wakeTranscribeWaiters() {
        let waiters = transcribeWaiters
        transcribeWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// Best-effort warm-up: bootstraps the engine and loads the requested model if it's installed.
    /// Silently no-ops if the model isn't downloaded, a run is active or queued, or load fails.
    public func prewarm(modelName: String) async {
        installPressureSourceIfNeeded()
        await ensureBootstrap()
        // Holds the transcribe slot: an overlapping prewarm would re-arm the idle timers
        // mid-run and swap the active transcriber out from under the run.
        guard modelStore.isInstalled(modelName), tryAcquireTranscribeSlot() else { return }
        defer { releaseTranscribeSlot() }
        let engineID = ModelCatalog.variant(id: modelName)?.engineID ?? .whisperKit
        do {
            cancelIdleTimer()
            defer { scheduleIdleUnload() }
            let active = try await ensureTranscriber(for: engineID)
            try await active.load(model: modelName)
        } catch {
        }
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
        if let allowed = managedConfiguration.allowedEngines, !allowed.contains(engineID) {
            throw ParolaError.policyRestricted(
                "The \(engineID.displayName) engine is disabled by a managed policy."
            )
        }
        if managedConfiguration.requireEnglishOnly,
           let language = options.language, language.lowercased() != "en" {
            throw ParolaError.policyRestricted(
                "Transcription is restricted to English by a managed policy."
            )
        }
        guard let baseCaps = await registry.capabilities(for: engineID) else {
            throw ParolaError.engineNotRegistered(engineID.rawValue)
        }
        let caps = baseCaps.tightened(by: variant?.languageScope)
        if let language = options.language, !caps.supportedLanguages.allows(language) {
            throw ParolaError.unsupportedForEngine(Self.languageRejection(
                language, engineID: engineID, variant: variant, supported: caps.supportedLanguages
            ))
        }
        if options.task == .translate, !caps.supportsTranslate {
            throw ParolaError.unsupportedForEngine("\(engineID.displayName) does not support translation.")
        }
        if options.diarize, !caps.supportsDiarization {
            throw ParolaError.unsupportedForEngine("\(engineID.displayName) does not support speaker labels.")
        }
    }

    /// Names the model rather than the engine: the usual cause is an English-only variant on an
    /// otherwise multilingual engine, and blaming the engine sends people looking in the wrong place.
    private static func languageRejection(
        _ language: String,
        engineID: EngineID,
        variant: ModelVariant?,
        supported: SupportedLanguages
    ) -> String {
        guard let variant else {
            return "\(engineID.displayName) can't transcribe \"\(language)\"."
        }
        var message = named(variant)
        if case .only(let codes) = supported, !codes.isEmpty {
            let spoken = codes == ["en"] ? "English" : codes.sorted().joined(separator: ", ")
            message += " only handles \(spoken) and"
        }
        message += " can't transcribe \"\(language)\"."
        if let alternative = ModelCatalog.variantSupporting(language: language, preferring: engineID) {
            message += " Pick a multilingual model such as \(named(alternative))."
        }
        return message
    }

    /// A display name that already carries a parenthetical would read as a double bracket.
    private static func named(_ variant: ModelVariant) -> String {
        variant.displayName.contains("(") ? variant.id : "\(variant.displayName) (\(variant.id))"
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

    private func defaultModelName(for options: TranscriptionOptions) -> String {
        ModelCatalog.defaultModelID(for: options, configuration: managedConfiguration)
    }

    /// The model a `transcribe` with these options would run, and whether it has to be fetched first.
    public func modelPlan(for options: TranscriptionOptions) -> (model: String, needsDownload: Bool) {
        let model = options.model ?? defaultModelName(for: options)
        return (model, !modelStore.isInstalled(model))
    }

    private func scheduleIdleUnload() {
        cancelIdleTimer()
        let modelTimeout = idleTimeout
        let diarizerTimeout = min(diarizerIdleTimeout, idleTimeout)
        let clock = clock
        idleEpoch &+= 1
        let myEpoch = idleEpoch
        diarizerIdleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(diarizerTimeout), clock: clock)
            if Task.isCancelled { return }
            await self?.unloadDiarizerIfIdle(epoch: myEpoch)
        }
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(modelTimeout), clock: clock)
            if Task.isCancelled { return }
            await self?.unloadIfIdle(epoch: myEpoch)
        }
    }

    private func unloadDiarizerIfIdle(epoch: Int) async {
        guard epoch == idleEpoch else { return }
        await diarizer.unload()
    }

    private func unloadIfIdle(epoch: Int) async {
        guard epoch == idleEpoch else { return }
        await unloadModel()
    }

    private func cancelIdleTimer() {
        idleTask?.cancel()
        idleTask = nil
        diarizerIdleTask?.cancel()
        diarizerIdleTask = nil
        // Invalidate any timer that already slipped past its isCancelled check, so it can't
        // unload mid-transcribe (cancel() alone doesn't bump the epoch its guard compares).
        idleEpoch &+= 1
    }

    private func installPressureSourceIfNeeded() {
        guard pressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: .critical, queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.unloadModel() }
        }
        source.activate()
        pressureSource = source
    }
}
