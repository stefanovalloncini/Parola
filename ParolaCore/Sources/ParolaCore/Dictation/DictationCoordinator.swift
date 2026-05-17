import Foundation

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
    private var eventTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<HotkeyEvent>.Continuation?

    private var pressStartedAt: Date?
    private var pendingHybridTimer: Task<Void, Never>?
    private var hybridLocked: Bool = false
    private static let hybridHoldThreshold: TimeInterval = 0.3

    public init(
        hotkey: any HotkeyMonitor,
        recorder: any DictationRecorder,
        inserter: any TextInserter,
        postProcessor: any TextPostProcessor = PassThroughPostProcessor(),
        mode: DictationMode = .pushToTalk,
        onStateChange: @escaping @Sendable (State) async -> Void = { _ in }
    ) {
        self.hotkey = hotkey
        self.recorder = recorder
        self.inserter = inserter
        self.postProcessor = postProcessor
        self.mode = mode
        self.onStateChange = onStateChange
    }

    deinit {
        eventContinuation?.finish()
        eventTask?.cancel()
    }

    public func setPostProcessor(_ processor: any TextPostProcessor) {
        postProcessor = processor
    }

    public func setMode(_ newMode: DictationMode) {
        mode = newMode
        pendingHybridTimer?.cancel()
        pendingHybridTimer = nil
        hybridLocked = false
    }

    public func startMonitoring() async {
        await hotkey.stop()
        eventTask?.cancel()
        eventContinuation?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: HotkeyEvent.self)
        eventContinuation = continuation
        eventTask = Task { [weak self] in
            for await event in stream {
                await self?.handle(event)
            }
        }
        await hotkey.start { event in
            continuation.yield(event)
        }
    }

    /// Stops listening for hotkeys. If a recording is in flight, transcribes and inserts it
    /// so the user's last utterance isn't dropped. Use ``abortMonitoring()`` for "give up"
    /// semantics that discard pending audio.
    public func stopMonitoring() async {
        await hotkey.stop()
        eventContinuation?.finish()
        eventContinuation = nil
        eventTask?.cancel()
        eventTask = nil
        if case .listening = state {
            await finishListening()
        } else {
            await setState(.idle)
        }
    }

    /// Stops listening and discards any in-flight recording without inserting text.
    public func abortMonitoring() async {
        await hotkey.stop()
        eventContinuation?.finish()
        eventContinuation = nil
        eventTask?.cancel()
        eventTask = nil
        if case .listening = state {
            _ = try? await recorder.stopAndTranscribe()
        }
        await setState(.idle)
    }

    public func simulatePress() async { await handle(.press) }
    public func simulateRelease() async { await handle(.release) }

    public func levels() async -> AsyncStream<Float> {
        await recorder.levels()
    }

    public func partials() async -> AsyncStream<String> {
        await recorder.partials()
    }

    func handle(_ event: HotkeyEvent) async {
        switch mode {
        case .pushToTalk:
            await handlePushToTalk(event)
        case .toggle:
            await handleToggle(event)
        case .hybrid:
            await handleHybrid(event)
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
        case .idle:
            await beginListening()
        case .listening:
            await finishListening()
        case .transcribing, .failed:
            break
        }
    }

    private func handleHybrid(_ event: HotkeyEvent) async {
        switch event {
        case .press:
            if state == .listening && hybridLocked {
                pressStartedAt = Date()
                return
            }
            pressStartedAt = Date()
            hybridLocked = false
            await beginListening()
        case .release:
            guard state == .listening else { return }
            let held = pressStartedAt.map { Date().timeIntervalSince($0) } ?? 0
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
        guard state == .idle else { return }
        do {
            try await recorder.start()
            await setState(.listening)
        } catch {
            await setState(.failed(error.localizedDescription))
            await setState(.idle)
        }
    }

    private func finishListening() async {
        guard state == .listening else { return }
        hybridLocked = false
        await setState(.transcribing)
        do {
            let raw = try await recorder.stopAndTranscribe()
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let processed = await postProcessor.process(trimmed)
                let final = processed.trimmingCharacters(in: .whitespacesAndNewlines)
                if !final.isEmpty {
                    await inserter.insert(final)
                }
            }
            await setState(.idle)
        } catch {
            await setState(.failed(error.localizedDescription))
            await setState(.idle)
        }
    }

    private func setState(_ new: State) async {
        state = new
        await onStateChange(new)
    }
}
