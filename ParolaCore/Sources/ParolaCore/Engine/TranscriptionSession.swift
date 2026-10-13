import Foundation
import os

/// Top-level orchestrator. Resolves the right `Transcriber` for the selected model via the
/// shared `EngineRegistry`, manages model loading, and emits transcription events.
///
/// Idle-unload: the diarizer is released after a short fixed idle; the active transcriber
/// stays warm until `idleTimeout` seconds of inactivity or memory pressure, then the next
/// transcribe call transparently reloads. Pressure during a run unloads when the run ends.
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
    private var transcriberIsMock = false
    private var modelIdle = IdleUnloadTimer()
    private var diarizerIdle = IdleUnloadTimer()
    private var pressureSource: (any DispatchSourceMemoryPressure)?
    private let observesMemoryPressure: Bool
    private var activeRun: Int?
    private var unloadWhenRunEnds = false
    private var lastRunID = 0
    private var transcribeWaiters: [CheckedContinuation<Void, Never>] = []
    private var diarizeStep: DiarizeStep?
    private var readabilityProbe: ReadabilityProbe = { FileAudioSource(url: $0).synchronousDuration() }

    /// How long the readability probe waits before the file counts as out of reach.
    private let fileReadDeadline: Duration
    private let fileReadClock: any Clock<Duration>

    /// How long a cancelled run has to unwind before its slot is taken away from it.
    private let abandonGrace: Duration

    typealias DiarizeStep = @Sendable (Transcript, URL, Int?) async throws -> Transcript
    typealias ReadabilityProbe = @Sendable (URL) -> Double?

    public init(
        modelStore: ModelStore = .shared,
        registry: EngineRegistry = .shared,
        idleTimeout: TimeInterval = 600,
        clock: any Clock<Duration> = ContinuousClock(),
        managedConfiguration: ManagedConfiguration = .shared,
        fileReadDeadline: Duration = FileReadDeadline.header,
        abandonGrace: Duration = .seconds(5),
        observesMemoryPressure: Bool = true
    ) {
        self.init(
            modelStore: modelStore,
            registry: registry,
            idleTimeout: idleTimeout,
            clock: clock,
            managedConfiguration: managedConfiguration,
            fileReadDeadline: fileReadDeadline,
            abandonGrace: abandonGrace,
            fileReadClock: ContinuousClock(),
            observesMemoryPressure: observesMemoryPressure
        )
    }

    /// The file-read deadlines keep their own clock, so a test clock driving them never counts the idle timers, or the reverse.
    init(
        modelStore: ModelStore = .shared,
        registry: EngineRegistry = .shared,
        idleTimeout: TimeInterval = 600,
        clock: any Clock<Duration> = ContinuousClock(),
        managedConfiguration: ManagedConfiguration = .shared,
        fileReadDeadline: Duration = FileReadDeadline.header,
        abandonGrace: Duration = .seconds(5),
        fileReadClock: any Clock<Duration>,
        observesMemoryPressure: Bool = true
    ) {
        self.observesMemoryPressure = observesMemoryPressure
        self.modelStore = modelStore
        self.registry = registry
        self.idleTimeout = idleTimeout
        self.clock = clock
        self.managedConfiguration = managedConfiguration
        self.fileReadDeadline = fileReadDeadline
        self.fileReadClock = fileReadClock
        self.abandonGrace = abandonGrace
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
        // Whole runs are serialized: interleaved calls would swap each other's transcriber out via
        // ensureTranscriber's unload and cross-wire the partial/progress callbacks. The exception
        // is a run abandoned after a cancel — its engine may still emit, so callers stamp their
        // handlers with a run of their own and drop what arrives late.
        let runID = try await acquireTranscribeSlot()
        defer { releaseTranscribeSlot(runID) }

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
        // An English-only model on auto language used to run per-chunk detection it can't act on;
        // pin it to English instead of leaving the run ambiguous. The frontends warn about this
        // themselves, since only they know whether to print it or show it inline.
        if options.language == nil, ModelCatalog.staticCapabilities(forID: modelName)?.supportedLanguages.isEnglishOnly == true {
            options.language = "en"
        }

        let capabilities = try await validate(options: options, engineID: engineID, variant: variant)
        options = Self.supportedOptions(options, capabilities: capabilities, engineID: engineID)
        let startedAt = ContinuousClock.now
        ParolaLog.info(
            .models, "transcribe starting on \(engineID)",
            [.model: .safe(ModelToken(modelName))]
        )

        // One read decides both the download and the engine that runs, so the two can't disagree.
        let mock = await registry.mock(for: engineID)
        if mock == nil, !modelStore.isInstalled(modelName) {
            _ = try await modelStore.download(
                variant: modelName, progress: downloadProgress, registry: registry
            )
        }
        try Task.checkCancellation()
        // The user's wait starts here, after any download: loading the model is part of it.
        let engineStartedAt = ContinuousClock.now
        cancelIdleTimer()
        // Rearm on every exit: a throw below (incl. cancellation) would otherwise leave the
        // loaded model resident with no idle timer until the next successful run. An abandoned
        // run no longer owns the slot, and its timers would outlive whatever took it over.
        defer { if activeRun == runID { scheduleIdleUnload() } }
        let activeTranscriber = try await ensureTranscriber(for: engineID, mock: mock)
        try await activeTranscriber.load(model: modelName)
        try Task.checkCancellation()

        let audioURL = try await source.prepare()
        try Task.checkCancellation()
        // The file is proved openable here, off the actor and on a deadline, rather than inside an
        // engine that would park in the same uninterruptible open() with the transcribe slot held.
        // The gate itself can run its full deadline, so a cancel during it arms the same abandon
        // the engine call uses rather than leaving the next run queued behind a stopped one.
        let probe = await withTaskCancellationHandler { [readabilityProbe] in
            await BoundedFileRead.run(deadline: fileReadDeadline, clock: fileReadClock) { readabilityProbe(audioURL) }
        } onCancel: {
            Task { await self.abandonIfCancelledRunStalls(runID) }
        }
        guard case .done(let probedDuration) = probe else {
            ParolaLog.error(
                .models, "file read timed out before the engine ran",
                [.model: .safe(ModelToken(modelName))]
            )
            throw ParolaError.fileReadTimedOut(name: audioURL.lastPathComponent)
        }
        // Abort engine work when the caller cancels: a hung engine (e.g. a stalled finalize)
        // would otherwise hold the transcribe slot and block every queued run until relaunch.
        var transcript: Transcript
        let windowEnergies = OSAllocatedUnfairLock<[Double]?>(initialState: nil)
        var handlers = TranscribeHandlers(onPartial: partialHandler, onProgress: progressHandler, onStage: stageHandler)
        handlers.onWindowEnergies = { energies in windowEnergies.withLock { $0 = energies } }
        do {
            transcript = try await withTaskCancellationHandler { [handlers] in
                try await activeTranscriber.transcribe(url: audioURL, options: options, handlers: handlers)
            } onCancel: {
                Task { await self.abandonIfCancelledRunStalls(runID) }
            }
        } catch {
            // Every engine hits this differently (a raw AVAudioFile throw, a wrapped CoreAudio
            // OSStatus, …); the file itself not decoding is the one thing they have in common.
            if !isCancellation(error), probedDuration == nil {
                ParolaLog.error(
                    .models, "transcribe failed on an unreadable file",
                    [.model: .safe(ModelToken(modelName)), .error: .error(error)]
                )
                throw ParolaError.unreadableFile(
                    name: audioURL.lastPathComponent,
                    reason: Self.unreadableFileReason(at: audioURL)
                )
            }
            throw error
        }
        // An engine can answer a cancel with the chunks that finished, as if the run were complete.
        try Task.checkCancellation()
        // The source asset's own duration, not whatever the engine decoded: engines disagree with
        // each other and Parakeet reports none at all. AVAudioFile can't open every container
        // FluidAudio decodes, so fall back to the AVURLAsset probe (on the same deadline as the
        // readability gate — AVFoundation's own asset queue can wedge exactly like AVAudioFile),
        // then the transcript itself.
        let estimatedDuration: Double? = probedDuration == nil
            ? await AsyncTimeout.run(fileReadDeadline, clock: fileReadClock) {
                await FileAudioSource(url: audioURL).estimatedDuration()
            } ?? nil
            : nil
        transcript.durationSeconds = probedDuration
            ?? estimatedDuration
            ?? transcript.segments.map(\.end).max()
        transcript = try await TranscriptFinisher.finish(
            transcript,
            engine: engineID,
            options: options,
            audioURL: audioURL,
            windowEnergies: windowEnergies.withLock { $0 },
            readDeadline: fileReadDeadline,
            readClock: fileReadClock
        ) { [options] tidied in
            var labelled = tidied
            if options.diarize {
                try Task.checkCancellation()
                labelled = try await self.diarize(
                    transcript: tidied,
                    audioURL: audioURL,
                    numberOfSpeakers: options.expectedSpeakers
                )
            }
            guard let sides = options.speakerSides else { return labelled }
            return await Self.labellingSides(labelled, sides)
        }
        let engineElapsed = engineStartedAt.duration(to: .now)
        transcript.transcriptionSeconds =
            Double(engineElapsed.components.seconds)
            + Double(engineElapsed.components.attoseconds) / 1e18
        ParolaLog.info(
            .models, "transcribe finished",
            [
                .model: .safe(ModelToken(modelName)),
                .engine: .safe(engineID),
                .elapsed: .duration(startedAt.duration(to: .now)),
                .count: .int(transcript.segments.count),
            ]
        )
        return transcript
    }

    /// After the diarizer and before sentences join, so no join carries one side's words into the other's segment.
    static func labellingSides(_ transcript: Transcript, _ sides: SpeakerSides) async -> Transcript {
        let segments = transcript.segments
        let read = await BoundedFileRead.run(deadline: FileReadDeadline.forReading(sides.stereo)) {
            Result { try SpeakerSideAttribution.label(segments: segments, stereo: sides.stereo, meLabel: sides.meLabel) }
        }
        guard case .done(.success(let labelled)) = read else {
            ParolaLog.notice(.models, "a meeting's two sides could not be read; its segments keep their speakers")
            return transcript
        }
        var sided = transcript
        sided.segments = labelled
        return sided
    }

    /// Stages speaker labels in place of SpeakerKit. Internal, so the CLI and both apps always
    /// run the real diarizer.
    func useDiarization(_ step: @escaping DiarizeStep) {
        diarizeStep = step
    }

    /// Stands in for the header read that proves a file opens. Internal, like `useDiarization`.
    func useReadabilityProbe(_ probe: @escaping ReadabilityProbe) {
        readabilityProbe = probe
    }

    var queuedRunCount: Int { transcribeWaiters.count }

    private func diarize(
        transcript: Transcript,
        audioURL: URL,
        numberOfSpeakers: Int?
    ) async throws -> Transcript {
        if let diarizeStep {
            return try await diarizeStep(transcript, audioURL, numberOfSpeakers)
        }
        return try await diarizer.diarize(
            transcript: transcript,
            audioURL: audioURL,
            numberOfSpeakers: numberOfSpeakers
        )
    }

    private func acquireTranscribeSlot() async throws -> Int {
        while activeRun != nil {
            try Task.checkCancellation()
            // On cancel, wake every waiter: the cancelled one re-loops into the check above
            // and throws; the rest re-queue.
            await withTaskCancellationHandler {
                await withCheckedContinuation { transcribeWaiters.append($0) }
            } onCancel: {
                Task { await self.wakeTranscribeWaiters() }
            }
        }
        return claimTranscribeSlot()
    }

    private func tryAcquireTranscribeSlot() -> Int? {
        guard activeRun == nil, transcribeWaiters.isEmpty else { return nil }
        return claimTranscribeSlot()
    }

    private func claimTranscribeSlot() -> Int {
        lastRunID &+= 1
        activeRun = lastRunID
        return lastRunID
    }

    private func releaseTranscribeSlot(_ runID: Int) {
        guard activeRun == runID else { return }
        activeRun = nil
        if unloadWhenRunEnds, transcribeWaiters.isEmpty {
            unloadWhenRunEnds = false
            cancelIdleTimer()
            let unloadRun = claimTranscribeSlot()
            Task { await self.unloadModel(holding: unloadRun) }
        }
        wakeTranscribeWaiters()
    }

    /// A cancelled run still inside the engine after the grace loses its slot and transcriber, so a parked read can't block every later run until relaunch.
    private func abandonIfCancelledRunStalls(_ runID: Int) async {
        // Only this run's own engine: a cancel delivered as the body completes must not reach into
        // whichever run has taken the slot since.
        guard activeRun == runID else { return }
        await cancelInFlight()
        try? await Task.sleep(for: abandonGrace)
        guard activeRun == runID else { return }
        // The zombie's engine keeps its weights resident until its parked read finally returns —
        // unload() would itself block, so the next run just loads a second copy.
        let zombieModel = await transcriber?.loadedModelName() ?? "unknown"
        guard activeRun == runID else { return }
        transcriber = nil
        transcriberEngineID = nil
        releaseTranscribeSlot(runID)
        ParolaLog.notice(
            .models, "abandoned a cancelled run that never unwound",
            [.model: .safe(ModelToken(zombieModel))]
        )
    }

    private func wakeTranscribeWaiters() {
        let waiters = transcribeWaiters
        transcribeWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// Best-effort warm-up: bootstraps the engine and loads the requested model if it's installed.
    /// No-ops if the model isn't downloaded, a run is active or queued, or load fails.
    public func prewarm(modelName: String) async {
        installPressureSourceIfNeeded()
        await ensureBootstrap()
        // Holds the transcribe slot: an overlapping prewarm would re-arm the idle timers
        // mid-run and swap the active transcriber out from under the run.
        guard modelStore.isInstalled(modelName), let runID = tryAcquireTranscribeSlot() else { return }
        defer { releaseTranscribeSlot(runID) }
        let engineID = ModelCatalog.variant(id: modelName)?.engineID ?? .whisperKit
        do {
            cancelIdleTimer()
            defer { scheduleIdleUnload() }
            let mock = await registry.mock(for: engineID)
            let active = try await ensureTranscriber(for: engineID, mock: mock)
            try await active.load(model: modelName)
        } catch {
            ParolaLog.debug(
                .models, "prewarm failed for \(ModelToken(modelName))", [.error: .error(error)]
            )
        }
    }

    /// Unloads `name` if it is the loaded model and no run is active or queued.
    public func unloadModel(ifLoaded name: String) async {
        guard let slot = tryAcquireTranscribeSlot() else { return }
        defer { releaseTranscribeSlot(slot) }
        guard await transcriber?.loadedModelName() == name else { return }
        await unloadModel()
    }

    /// A run in flight keeps its model: unloading under it frees nothing and breaks what it still reads.
    func unloadUnderPressure() async {
        guard let slot = tryAcquireTranscribeSlot() else {
            unloadWhenRunEnds = true
            return
        }
        await unloadModel(holding: slot)
    }

    private func unloadModel(holding slot: Int) async {
        await unloadModel()
        releaseTranscribeSlot(slot)
    }

    public func unloadModel() async {
        cancelIdleTimer()
        unloadWhenRunEnds = false
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

    /// Drops a prompt or word timings the engine can't produce instead of failing the run.
    static func supportedOptions(
        _ options: TranscriptionOptions,
        capabilities: EngineCapabilities,
        engineID: EngineID
    ) -> TranscriptionOptions {
        var options = options
        if options.initialPrompt != nil, !capabilities.supportsInitialPrompt {
            ParolaLog.notice(.models, "engine \(engineID) takes no prompt; dropped it")
            options.initialPrompt = nil
        }
        if options.wordTimestamps, !capabilities.supportsWordTimestamps {
            ParolaLog.notice(.models, "engine \(engineID) emits no word timings; dropped the request")
            options.wordTimestamps = false
        }
        return options
    }

    private func validate(
        options: TranscriptionOptions,
        engineID: EngineID,
        variant: ModelVariant?
    ) async throws -> EngineCapabilities {
        if let allowed = managedConfiguration.allowedEngines, !allowed.contains(engineID) {
            ParolaLog.notice(.models, "rejected by policy: engine \(engineID)")
            throw ParolaError.policyRestricted(
                FixedFailureText.engineDisabled(engineID.displayName)
            )
        }
        if managedConfiguration.requireEnglishOnly,
           let language = options.language, language.lowercased() != "en" {
            ParolaLog.notice(.models, "rejected by policy: language")
            throw ParolaError.policyRestricted(
                FixedFailureText.englishOnly
            )
        }
        guard let baseCaps = await registry.capabilities(for: engineID) else {
            ParolaLog.error(.models, "engine \(engineID) is not registered")
            throw ParolaError.engineNotRegistered(engineID.rawValue)
        }
        let caps = baseCaps.tightened(by: variant?.languageScope)
        if let language = options.language, !caps.supportedLanguages.allows(language) {
            ParolaLog.notice(
                .models, "engine \(engineID) rejected language",
                [.language: .safe(LanguageToken(language))]
            )
            throw ParolaError.unsupportedForEngine(Self.languageRejection(
                language, engineID: engineID, variant: variant, supported: caps.supportedLanguages
            ))
        }
        if options.task == .translate, !caps.supportsTranslate {
            ParolaLog.notice(.models, "engine \(engineID) rejected translate")
            throw ParolaError.unsupportedForEngine(FixedFailureText.cannotTranslate(engineID.displayName))
        }
        if options.diarize, !caps.supportsDiarization {
            ParolaLog.notice(.models, "engine \(engineID) rejected diarize")
            throw ParolaError.unsupportedForEngine(FixedFailureText.cannotLabelSpeakers(engineID.displayName))
        }
        return caps
    }

    /// The only cause worth naming without reading the file's bytes — everything else stays silent rather than guess.
    static func unreadableFileReason(at url: URL) -> String? {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64,
              size == 0 else { return nil }
        return FixedFailureText.fileIsEmpty
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
        variant.displayName.contains("(") ? variant.displayName : "\(variant.displayName) (\(variant.id))"
    }

    private func ensureBootstrap() async {
        let registered = await registry.registeredEngines()
        if registered.isEmpty {
            await ParolaCoreBootstrap.registerBuiltInEngines(registry: registry)
        }
    }

    private func ensureTranscriber(
        for engineID: EngineID,
        mock: MockTranscriberResponse?
    ) async throws -> any Transcriber {
        if let existing = transcriber, transcriberEngineID == engineID, transcriberIsMock == (mock != nil) {
            return existing
        }
        if let old = transcriber {
            await old.unload()
        }
        let fresh = try await registry.transcriber(for: engineID, store: modelStore, mock: mock)
        transcriber = fresh
        transcriberEngineID = engineID
        transcriberIsMock = mock != nil
        return fresh
    }

    private func defaultModelName(for options: TranscriptionOptions) -> String {
        ModelCatalog.defaultModelID(for: options, configuration: managedConfiguration)
    }

    /// The model a `transcribe` with these options would run, and whether it has to be fetched first.
    public func modelPlan(for options: TranscriptionOptions) async -> (model: String, needsDownload: Bool) {
        let model = options.model ?? defaultModelName(for: options)
        guard !modelStore.isInstalled(model) else { return (model, false) }
        let engineID = ModelCatalog.variant(id: model)?.engineID ?? .whisperKit
        return (model, await registry.mock(for: engineID) == nil)
    }

    private func scheduleIdleUnload() {
        diarizerIdle.arm(after: .seconds(min(diarizerIdleTimeout, idleTimeout)), clock: clock) { [weak self] epoch in
            await self?.unloadDiarizerIfIdle(epoch: epoch)
        }
        modelIdle.arm(after: .seconds(idleTimeout), clock: clock) { [weak self] epoch in
            await self?.unloadIfIdle(epoch: epoch)
        }
    }

    private func unloadDiarizerIfIdle(epoch: Int) async {
        guard diarizerIdle.isCurrent(epoch) else { return }
        await diarizer.unload()
    }

    private func unloadIfIdle(epoch: Int) async {
        guard modelIdle.isCurrent(epoch) else { return }
        await unloadModel()
        ParolaLog.info(.models, "model unloaded after idle", [.elapsed: .seconds(idleTimeout)])
    }

    private func cancelIdleTimer() {
        modelIdle.disarm()
        diarizerIdle.disarm()
    }

    private func installPressureSourceIfNeeded() {
        guard observesMemoryPressure, pressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.unloadUnderPressure() }
        }
        source.activate()
        pressureSource = source
    }
}
