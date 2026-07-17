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

    public init(
        hotkey: any HotkeyMonitor,
        recorder: any DictationRecorder,
        inserter: any TextInserter,
        postProcessor: (any TextPostProcessor)? = nil,
        mode: DictationMode = .pushToTalk,
        mediaSession: MediaSession? = nil,
        mediaConfigProvider: (@Sendable () async -> MediaSessionConfig)? = nil,
        onStateChange: @escaping @Sendable (State) async -> Void
    ) {
        self.hotkey = hotkey
        self.recorder = recorder
        self.inserter = inserter
        self.postProcessor = postProcessor ?? PassThroughPostProcessor()
        self.mode = mode
        self.mediaSession = mediaSession
        self.mediaConfigProvider = mediaConfigProvider
        self.onStateChange = onStateChange
    }

    public init(
        hotkey: any HotkeyMonitor,
        recorder: any DictationRecorder,
        inserter: any TextInserter,
        postProcessor: (any TextPostProcessor)? = nil,
        mode: DictationMode = .pushToTalk,
        mediaSession: MediaSession? = nil,
        mediaConfigProvider: (@Sendable () async -> MediaSessionConfig)? = nil
    ) {
        self.hotkey = hotkey
        self.recorder = recorder
        self.inserter = inserter
        self.postProcessor = postProcessor ?? PassThroughPostProcessor()
        self.mode = mode
        self.mediaSession = mediaSession
        self.mediaConfigProvider = mediaConfigProvider
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
    /// so the user's last utterance isn't dropped. Use ``abortMonitoring()`` for "give up"
    /// semantics that discard pending audio.
    public func stopMonitoring() async {
        shutDown = true
        generation &+= 1
        await teardownMonitor()
        if case .listening = state {
            await finishListening()
        } else {
            await setState(.idle)
        }
    }

    /// Stops listening and discards any in-flight recording without inserting text.
    public func abortMonitoring() async {
        shutDown = true
        generation &+= 1
        await teardownMonitor()
        if case .listening = state {
            await mediaSession?.exitRecording()
            await recorder.stopAndDiscard()
        }
        await setState(.idle)
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
        if case .listening = state {
            await finishListening()
        }
    }

    public func levels() async -> AsyncStream<Float> {
        await recorder.levels()
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
        switch state {
        case .idle, .failed:
            await beginListening()
        case .listening:
            await finishListening()
        case .transcribing:
            break
        }
    }

    private func handleHybrid(_ event: HotkeyEvent, capturedAt: Date) async {
        switch event {
        case .press:
            pressStartedAt = capturedAt
            if state == .listening && hybridLocked { return }
            hybridLocked = false
            await beginListening()
        case .release:
            guard state == .listening else { return }
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
        // .failed is a resting state too: a new press recovers from a prior error.
        switch state {
        case .idle, .failed: break
        default: return
        }
        generation &+= 1
        let myGeneration = generation
        startInFlight = true
        releaseDuringStart = false
        stopRequestedDuringStart = false
        if let session = mediaSession {
            let config = await mediaConfigProvider?() ?? .none
            await session.enterRecording(config: config)
        }
        do {
            try await recorder.start()
        } catch {
            startInFlight = false
            guard myGeneration == generation else { return }
            await mediaSession?.exitRecording()
            await setState(.failed(error.localizedDescription))
            return
        }
        startInFlight = false
        guard myGeneration == generation else {
            await mediaSession?.exitRecording()
            await recorder.stopAndDiscard()
            return
        }
        await setState(.listening)
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
        guard state == .listening else { return }
        generation &+= 1
        hybridLocked = false
        await setState(.transcribing)
        await mediaSession?.exitRecording()
        do {
            let raw = try await recorder.stopAndTranscribe()
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let processed = await postProcessor.process(trimmed)
                let final = SnippetMarker.stripped(processed).trimmingCharacters(in: .whitespacesAndNewlines)
                if !final.isEmpty {
                    try await inserter.insert(final)
                }
            }
            await setState(.idle)
        } catch {
            await setState(.failed(error.localizedDescription))
        }
    }

    private func setState(_ new: State) async {
        state = new
        await onStateChange(new)
    }
}
