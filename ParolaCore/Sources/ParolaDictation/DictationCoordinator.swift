import Foundation
import ParolaCore

public actor DictationCoordinator {
    public enum State: Sendable, Equatable {
        case idle
        case listening
        case transcribing
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var mode: DictationMode

    private let hotkey: any HotkeyMonitor
    private let recorder: any DictationRecorder
    private let inserter: any TextInserter
    private var postProcessor: any TextPostProcessor
    private let onStateChange: @Sendable (State) async -> Void
    private var mediaSession: MediaSession?
    private var mediaConfigProvider: (@Sendable () async -> MediaSessionConfig)?
    private var configurationProvider: (@Sendable () async -> DictationPipelineConfiguration)?
    private var targetProvider: (@Sendable (DictationPipelineConfiguration) async -> DictationTarget?)?
    private var willListen: (@Sendable () async -> Void)?
    private var eventTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<(HotkeyEvent, Date)>.Continuation?

    private var pressStartedAt: Date?
    private var hybridLocked: Bool = false
    private static let hybridHoldThreshold: TimeInterval = 0.3

    /// Bumped by every transition that leaves (or gives up) the listening state. `beginListening`
    /// captures it before its awaits and rolls back its own setup if a teardown raced it — the
    /// actor is reentrant, so a stop/abort can run while `recorder.start()` is still suspended.
    private var generation: UInt64 = 0

    /// True while `beginListening` is awaiting `recorder.start()`. The actor is reentrant, so a
    /// release can land before the recorder is up; we defer it and replay it once `.listening` is
    /// real, so `.listening` never reports a session that can't yet be stopped-and-transcribed.
    private var startInFlight = false
    private var releaseDuringStart = false
    private var releaseDuringStartAt: Date?
    private var stopRequestedDuringStart = false

    /// Set before the teardown awaits: an event that enters `handle` while stop/abort is
    /// suspended would otherwise pass the state guard, bump the generation itself, and
    /// revive a live recorder nobody owns anymore (hot mic, stuck HUD).
    private var shutDown = false

    private struct Job {
        let settle: AsyncStream<Void>.Continuation
        var take: DictationTake?
        var finalizing: Task<String, any Error>?
    }

    /// True from the moment a capture ends until the recorder is free and the state is published; a press in between is replayed after.
    private var endInFlight = false
    private var deferredEvents: [(event: HotkeyEvent, at: Date)] = []

    private var isListening = false
    private var resting: State = .idle
    private var processing = 0
    private var captureConfiguration: DictationPipelineConfiguration?
    private var jobs: [UInt64: Job] = [:]
    private var lastSettled: AsyncStream<Void>?
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    private var finishes: UInt64 = 0

    private let features: FeatureSet

    public init(
        hotkey: any HotkeyMonitor,
        recorder: any DictationRecorder,
        inserter: any TextInserter,
        postProcessor: (any TextPostProcessor)? = nil,
        mode: DictationMode = .pushToTalk,
        mediaSession: MediaSession? = nil,
        mediaConfigProvider: (@Sendable () async -> MediaSessionConfig)? = nil,
        configurationProvider: (@Sendable () async -> DictationPipelineConfiguration)? = nil,
        targetProvider: (@Sendable (DictationPipelineConfiguration) async -> DictationTarget?)? = nil,
        willListen: (@Sendable () async -> Void)? = nil,
        features: FeatureSet = .resolve(),
        onStateChange: @escaping @Sendable (State) async -> Void
    ) {
        self.hotkey = hotkey
        self.recorder = recorder
        self.inserter = inserter
        self.postProcessor = postProcessor ?? PassThroughPostProcessor()
        self.mode = mode
        self.mediaSession = mediaSession
        self.mediaConfigProvider = mediaConfigProvider
        self.configurationProvider = configurationProvider
        self.targetProvider = targetProvider
        self.willListen = willListen
        self.features = features
        self.onStateChange = onStateChange
    }

    public init(
        hotkey: any HotkeyMonitor,
        recorder: any DictationRecorder,
        inserter: any TextInserter,
        postProcessor: (any TextPostProcessor)? = nil,
        mode: DictationMode = .pushToTalk,
        mediaSession: MediaSession? = nil,
        mediaConfigProvider: (@Sendable () async -> MediaSessionConfig)? = nil,
        configurationProvider: (@Sendable () async -> DictationPipelineConfiguration)? = nil,
        targetProvider: (@Sendable (DictationPipelineConfiguration) async -> DictationTarget?)? = nil,
        willListen: (@Sendable () async -> Void)? = nil,
        features: FeatureSet = .resolve()
    ) {
        self.hotkey = hotkey
        self.recorder = recorder
        self.inserter = inserter
        self.postProcessor = postProcessor ?? PassThroughPostProcessor()
        self.mode = mode
        self.mediaSession = mediaSession
        self.mediaConfigProvider = mediaConfigProvider
        self.configurationProvider = configurationProvider
        self.targetProvider = targetProvider
        self.willListen = willListen
        self.features = features
        self.onStateChange = { _ in }
    }

    deinit {
        eventContinuation?.finish()
        eventTask?.cancel()
    }

    public func setPostProcessor(_ processor: any TextPostProcessor) {
        postProcessor = processor
    }

    public func setMediaSession(_ session: MediaSession?, configProvider: (@Sendable () async -> MediaSessionConfig)?) {
        mediaSession = session
        mediaConfigProvider = configProvider
    }

    public func setMode(_ newMode: DictationMode) {
        mode = newMode
        hybridLocked = false
    }

    public func startMonitoring() async {
        guard features.isEnabled(.dictation) else { return }
        shutDown = false
        await hotkey.stop()
        eventTask?.cancel()
        eventContinuation?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: (HotkeyEvent, Date).self)
        eventContinuation = continuation
        eventTask = Task { [weak self] in
            for await (event, capturedAt) in stream {
                await self?.handle(event, capturedAt: capturedAt)
            }
        }
        // Stamp at capture: events are handled serially behind recorder start/stop awaits,
        // so handling time is not press/release time.
        await hotkey.start { event in
            continuation.yield((event, Date()))
        }
    }

    /// Stops listening for hotkeys. If a recording is in flight, transcribes and inserts it
    /// so the user's last utterance isn't dropped. With `waitingForTakes`, it also waits for every earlier take to land;
    /// without it, they finish on their own, so a stuck take never holds up the next coordinator.
    /// Use ``abortMonitoring()`` for "give up" semantics that discard pending audio.
    public func stopMonitoring(waitingForTakes: Bool = true) async {
        shutDown = true
        generation &+= 1
        await teardownMonitor()
        if isListening {
            await finishListening()
        } else {
            resting = .idle
        }
        if waitingForTakes { await drain() }
        await publishState()
    }

    /// Stops listening and discards any in-flight recording and every take not yet inserted.
    public func abortMonitoring() async {
        shutDown = true
        generation &+= 1
        await teardownMonitor()
        if isListening {
            isListening = false
            captureConfiguration = nil
            await mediaSession?.exitRecording(holder: .dictation)
            await recorder.stopAndDiscard()
        } else if startInFlight {
            await recorder.stopAndDiscard()
        }
        await dropTakes(Array(jobs.keys))
        resting = .idle
        await publishState()
    }

    /// Drops the take being recorded and leaves the ones still being processed alone.
    public func cancelListening() async {
        guard isListening else { return }
        generation &+= 1
        isListening = false
        captureConfiguration = nil
        hybridLocked = false
        endInFlight = true
        await publishState()
        await mediaSession?.exitRecording(holder: .dictation)
        await recorder.stopAndDiscard()
        await finishEnding()
    }

    /// Waits until every released take has been inserted, failed or dropped.
    public func drain() async {
        guard processing > 0 else { return }
        await withCheckedContinuation { drainWaiters.append($0) }
    }

    private func finishEnding() async {
        endInFlight = false
        let replay = deferredEvents
        deferredEvents = []
        for (event, at) in replay { await handle(event, capturedAt: at) }
    }

    /// A release or a second tap that comes while its press is still held back cancels that press, so the mic never opens for a tap already over.
    private func deferEvent(_ event: HotkeyEvent, at capturedAt: Date) {
        let pendingPress: Bool = { if case .press? = deferredEvents.last?.event { true } else { false } }()
        switch (mode, event) {
        case (.pushToTalk, .press):
            deferredEvents.append((event, capturedAt))
        case (.pushToTalk, .release):
            if pendingPress { deferredEvents.removeLast() }
        case (.toggle, .press):
            if pendingPress { deferredEvents.removeLast() } else { deferredEvents.append((event, capturedAt)) }
        case (.toggle, .release):
            break
        case (.hybrid, .press):
            if deferredEvents.count == 2, case .release = deferredEvents[1].event {
                deferredEvents = []
            } else if !pendingPress {
                deferredEvents.append((event, capturedAt))
            }
        case (.hybrid, .release):
            guard pendingPress, let pressedAt = deferredEvents.last?.at else { return }
            if capturedAt.timeIntervalSince(pressedAt) >= Self.hybridHoldThreshold {
                deferredEvents.removeLast()
            } else {
                deferredEvents.append((event, capturedAt))
            }
        }
    }

    private func teardownMonitor() async {
        await hotkey.stop()
        eventContinuation?.finish()
        eventContinuation = nil
        eventTask?.cancel()
        eventTask = nil
    }

    public func simulatePress() async { await handle(.press) }
    public func simulateRelease() async { await handle(.release) }

    /// Explicit stop for UI affordances (HUD button, menu bar, intents): finishes the
    /// session in every mode, unlike a `.release` event, which toggle mode ignores.
    public func stopListening() async {
        guard !shutDown else { return }
        if startInFlight {
            stopRequestedDuringStart = true
            return
        }
        if isListening {
            await finishListening()
        } else if processing == 0, case .failed = resting {
            resting = .idle
            await publishState()
        }
    }

    /// Gives up on the take being processed now, the oldest one: its late text is never inserted and queued takes still run.
    /// Returns false when none is running.
    @discardableResult
    public func abandonTranscription() async -> Bool {
        guard case .transcribing = state, let oldest = jobs.keys.min() else { return false }
        return await abandon(oldest)
    }

    /// Waits up to `limit` for the take being processed now, then gives that one up as
    /// ``abandonTranscription()`` does. A take that starts meanwhile is never touched.
    public func giveUpOnTranscription(after limit: Duration) async -> Bool {
        guard case .transcribing = state, let oldest = jobs.keys.min() else { return false }
        try? await Task.sleep(for: limit)
        return await abandon(oldest)
    }

    private func abandon(_ id: UInt64) async -> Bool {
        guard case .transcribing = state, jobs[id] != nil else { return false }
        ParolaLog.notice(.dictation, "final transcription abandoned in \(mode)")
        await dropTakes([id])
        await publishState()
        return true
    }

    private func dropTakes(_ ids: [UInt64], cancelling: Bool = true) async {
        for id in ids {
            guard let job = jobs.removeValue(forKey: id) else { continue }
            processing -= 1
            job.settle.finish()
            if cancelling {
                job.finalizing?.cancel()
                await job.take?.discard()
            }
        }
        resumeDrainWaitersIfIdle()
    }

    public func levelMeter() async -> LevelMeter? {
        await recorder.levelMeter()
    }

    public func partials() async -> AsyncStream<String> {
        await recorder.partials()
    }

    func handle(_ event: HotkeyEvent, capturedAt: Date = Date()) async {
        guard !shutDown else { return }
        if startInFlight {
            if case .release = event {
                releaseDuringStart = true
                releaseDuringStartAt = capturedAt
            }
            // A press while the start is in flight would pass the .idle guard and
            // double-start the recorder, orphaning the first session.
            return
        }
        if endInFlight {
            deferEvent(event, at: capturedAt)
            return
        }
        switch mode {
        case .pushToTalk:
            await handlePushToTalk(event)
        case .toggle:
            await handleToggle(event)
        case .hybrid:
            await handleHybrid(event, capturedAt: capturedAt)
        }
    }

    private func handlePushToTalk(_ event: HotkeyEvent) async {
        switch event {
        case .press:
            await beginListening()
        case .release:
            await finishListening()
        }
    }

    private func handleToggle(_ event: HotkeyEvent) async {
        guard case .press = event else { return }
        if isListening {
            await finishListening()
        } else {
            await beginListening()
        }
    }

    private func handleHybrid(_ event: HotkeyEvent, capturedAt: Date) async {
        switch event {
        case .press:
            // Only a press that starts a session may move the hold clock: an intent press
            // landing mid-hold would otherwise make the real key-up read as a quick tap.
            guard !isListening else { return }
            pressStartedAt = capturedAt
            hybridLocked = false
            await beginListening()
        case .release:
            guard isListening else { return }
            let held = pressStartedAt.map { capturedAt.timeIntervalSince($0) } ?? 0
            pressStartedAt = nil
            if hybridLocked {
                hybridLocked = false
                await finishListening()
                return
            }
            if held >= Self.hybridHoldThreshold {
                await finishListening()
            } else {
                hybridLocked = true
            }
        }
    }

    private func beginListening() async {
        guard !isListening else { return }
        if case .failed = state { resting = .idle }
        generation &+= 1
        let myGeneration = generation
        startInFlight = true
        releaseDuringStart = false
        stopRequestedDuringStart = false
        let configuration = await configurationProvider?()
        // After startInFlight: a press during this await must hit handle's start-in-flight guard.
        await willListen?()
        guard myGeneration == generation else {
            startInFlight = false
            return
        }
        if let session = mediaSession {
            let config = await mediaConfigProvider?() ?? .none
            await session.enterRecording(config: config, holder: .dictation)
            if myGeneration != generation {
                startInFlight = false
                await session.exitRecording(holder: .dictation)
                return
            }
        }
        do {
            if let configuration {
                try await recorder.start(configuration: configuration)
            } else {
                try await recorder.start()
            }
        } catch {
            if error is CancellationError {
                ParolaLog.info(.dictation, "dictation start was cancelled in \(mode)")
            } else {
                ParolaLog.error(
                    .dictation, "dictation recorder failed to start in \(mode)",
                    [.error: .error(error)]
                )
            }
            startInFlight = false
            // The media session was entered before the start, so it is left even when a teardown superseded this start.
            await mediaSession?.exitRecording(holder: .dictation)
            guard myGeneration == generation else { return }
            resting = .failed(error.localizedDescription)
            await publishState()
            return
        }
        startInFlight = false
        guard myGeneration == generation else {
            await mediaSession?.exitRecording(holder: .dictation)
            await recorder.stopAndDiscard()
            return
        }
        isListening = true
        captureConfiguration = configuration
        await publishState()
        if stopRequestedDuringStart {
            stopRequestedDuringStart = false
            releaseDuringStart = false
            releaseDuringStartAt = nil
            await finishListening()
            return
        }
        if releaseDuringStart {
            releaseDuringStart = false
            let releasedAt = releaseDuringStartAt ?? Date()
            releaseDuringStartAt = nil
            await handle(.release, capturedAt: releasedAt)
        }
    }

    private func finishListening() async {
        guard isListening else { return }
        generation &+= 1
        finishes &+= 1
        let id = finishes
        hybridLocked = false
        isListening = false
        processing += 1
        endInFlight = true
        let configuration = captureConfiguration
        captureConfiguration = nil
        let (settled, settle) = AsyncStream<Void>.makeStream()
        let previous = lastSettled
        lastSettled = settled
        jobs[id] = Job(settle: settle)
        let binding = Task { await bindTake(configuration) }
        let startedAt = ContinuousClock.now
        await publishState()
        await mediaSession?.exitRecording(holder: .dictation)
        let take: DictationTake
        do {
            take = try await recorder.stopCapture()
        } catch {
            binding.cancel()
            await failJob(id, error, startedAt: startedAt)
            await finishEnding()
            return
        }
        guard jobs[id] != nil else {
            binding.cancel()
            await take.discard()
            await finishEnding()
            return
        }
        let finalizing = Task { try await take.finalize() }
        jobs[id]?.take = take
        jobs[id]?.finalizing = finalizing
        Task {
            await complete(id, finalizing: finalizing, binding: binding, after: previous, startedAt: startedAt)
        }
        await finishEnding()
    }

    private func bindTake(_ configuration: DictationPipelineConfiguration?) async -> DictationTakeBinding {
        guard let configuration else { return DictationTakeBinding(postProcessor: postProcessor, inserter: inserter) }
        guard let bind = configuration.bind else {
            return DictationTakeBinding(postProcessor: configuration.postProcessor, inserter: inserter)
        }
        return bind(await targetProvider?(configuration))
    }

    private func complete(
        _ id: UInt64,
        finalizing: Task<String, any Error>,
        binding: Task<DictationTakeBinding, Never>,
        after previous: AsyncStream<Void>?,
        startedAt: ContinuousClock.Instant
    ) async {
        let raw = await finalizing.result
        if let previous { for await _ in previous {} }
        guard jobs[id] != nil else { return }
        let bound = await binding.value
        do {
            let trimmed = try raw.get().trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, jobs[id] != nil {
                let processed = await bound.postProcessor.process(trimmed)
                let final = SnippetMarker.stripped(processed).trimmingCharacters(in: .whitespacesAndNewlines)
                if !final.isEmpty, jobs[id] != nil {
                    try await bound.inserter.insert(final)
                }
            }
        } catch {
            if jobs[id] != nil { noteFailure(error, startedAt: startedAt) }
        }
        guard let job = jobs.removeValue(forKey: id) else { return }
        processing -= 1
        job.settle.finish()
        await publishState()
        resumeDrainWaitersIfIdle()
    }

    private func resumeDrainWaitersIfIdle() {
        guard processing == 0 else { return }
        let waiters = drainWaiters
        drainWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func noteFailure(_ error: any Error, startedAt: ContinuousClock.Instant) {
        ParolaLog.error(
            .dictation, "dictation finish failed in \(mode)",
            [.elapsed: .duration(startedAt.duration(to: .now)), .error: .error(error)]
        )
        resting = .failed(error.localizedDescription)
    }

    private func failJob(_ id: UInt64, _ error: any Error, startedAt: ContinuousClock.Instant) async {
        guard let job = jobs.removeValue(forKey: id) else { return }
        processing -= 1
        job.settle.finish()
        noteFailure(error, startedAt: startedAt)
        await publishState()
        resumeDrainWaitersIfIdle()
    }

    private func publishState() async {
        let next: State
        if isListening {
            next = .listening
        } else if processing > 0 {
            next = .transcribing
        } else {
            next = resting
        }
        guard next != state else { return }
        ParolaLog.debug(.dictation, "dictation state → \(next)")
        state = next
        await onStateChange(next)
    }
}
