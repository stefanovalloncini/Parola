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
        let finalizing: Task<String, any Error>
        let take: DictationTake
        let settle: AsyncStream<Void>.Continuation
    }

    private var isListening = false
    private var resting: State = .idle
    private var processing = 0
    private var captureConfiguration: DictationPipelineConfiguration?
    private var jobs: [UInt64: Job] = [:]
    private var lastSettled: AsyncStream<Void>?
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    /// Counts released takes; one a stop gave up on stays at or below `abandonedFinishes`, so its late text is dropped.
    private var finishes: UInt64 = 0
    private var abandonedFinishes: UInt64 = 0

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
    /// so the user's last utterance isn't dropped, and waits for every earlier take to land.
    /// Use ``abortMonitoring()`` for "give up" semantics that discard pending audio.
    public func stopMonitoring() async {
        shutDown = true
        generation &+= 1
        await teardownMonitor()
        if isListening {
            await finishListening()
        } else {
            resting = .idle
        }
        await drain()
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
        await dropTakes(upTo: finishes)
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
        await publishState()
        await mediaSession?.exitRecording(holder: .dictation)
        await recorder.stopAndDiscard()
    }

    /// Waits until every released take has been inserted, failed or dropped.
    public func drain() async {
        guard !jobs.isEmpty else { return }
        await withCheckedContinuation { drainWaiters.append($0) }
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

    /// Gives up on the final transcription under way now: the session goes idle and its late text is never inserted.
    /// Returns false when none is running. The recorder can stay busy, so the caller replaces this coordinator afterwards.
    @discardableResult
    public func abandonTranscription() async -> Bool {
        guard case .transcribing = state else { return false }
        return await abandon(finishes)
    }

    /// Waits up to `limit` for the final transcription under way now, then gives that one up as
    /// ``abandonTranscription()`` does. A session that starts meanwhile is never touched.
    public func giveUpOnTranscription(after limit: Duration) async -> Bool {
        guard case .transcribing = state else { return false }
        let finish = finishes
        try? await Task.sleep(for: limit)
        return await abandon(finish)
    }

    private func abandon(_ finish: UInt64) async -> Bool {
        guard case .transcribing = state, finish == finishes, finish > abandonedFinishes else { return false }
        ParolaLog.notice(.dictation, "final transcription abandoned in \(mode)")
        await dropTakes(upTo: finish, cancelling: false)
        resting = .idle
        await publishState()
        return true
    }

    private func dropTakes(upTo finish: UInt64, cancelling: Bool = true) async {
        abandonedFinishes = max(abandonedFinishes, finish)
        let dropped = jobs.filter { $0.key <= finish }
        for (id, job) in dropped {
            jobs[id] = nil
            processing -= 1
            job.settle.finish()
            if cancelling {
                job.finalizing.cancel()
                await job.take.discard()
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
        resting = .idle
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
        let configuration = captureConfiguration
        captureConfiguration = nil
        await publishState()
        await mediaSession?.exitRecording(holder: .dictation)
        let startedAt = ContinuousClock.now
        let take: DictationTake
        do {
            take = try await recorder.stopCapture()
        } catch {
            guard id > abandonedFinishes else { return }
            processing -= 1
            await fail(error, startedAt: startedAt)
            return
        }
        guard id > abandonedFinishes else {
            processing -= 1
            await take.discard()
            await publishState()
            return
        }
        let target = await inserter.bound(to: configuration)
        let processor = configuration?.postProcessor ?? postProcessor
        let finalizing = Task { try await take.finalize() }
        let (settled, settle) = AsyncStream<Void>.makeStream()
        let previous = lastSettled
        lastSettled = settled
        jobs[id] = Job(finalizing: finalizing, take: take, settle: settle)
        Task { [weak self] in
            await self?.complete(
                id, finalizing: finalizing, after: previous, processor: processor, target: target, startedAt: startedAt
            )
        }
    }

    private func complete(
        _ id: UInt64,
        finalizing: Task<String, any Error>,
        after previous: AsyncStream<Void>?,
        processor: any TextPostProcessor,
        target: any TextInserter,
        startedAt: ContinuousClock.Instant
    ) async {
        let raw = await finalizing.result
        if let previous { for await _ in previous {} }
        guard let job = jobs[id], id > abandonedFinishes else { return }
        do {
            let trimmed = try raw.get().trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let processed = await processor.process(trimmed)
                let final = SnippetMarker.stripped(processed).trimmingCharacters(in: .whitespacesAndNewlines)
                if !final.isEmpty, id > abandonedFinishes {
                    try await target.insert(final)
                }
            }
            if id > abandonedFinishes { resting = .idle }
        } catch {
            if id > abandonedFinishes {
                ParolaLog.error(
                    .dictation, "dictation finish failed in \(mode)",
                    [.elapsed: .duration(startedAt.duration(to: .now)), .error: .error(error)]
                )
                resting = .failed(error.localizedDescription)
            }
        }
        guard jobs[id] != nil else { return }
        jobs[id] = nil
        processing -= 1
        job.settle.finish()
        await publishState()
        resumeDrainWaitersIfIdle()
    }

    private func resumeDrainWaitersIfIdle() {
        guard jobs.isEmpty else { return }
        let waiters = drainWaiters
        drainWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func fail(_ error: any Error, startedAt: ContinuousClock.Instant) async {
        ParolaLog.error(
            .dictation, "dictation finish failed in \(mode)",
            [.elapsed: .duration(startedAt.duration(to: .now)), .error: .error(error)]
        )
        resting = .failed(error.localizedDescription)
        await publishState()
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
