import Foundation
import os
@preconcurrency import WhisperKit
#if os(macOS)
import CoreAudio
import CoreGraphics
#endif

/// A failure whose text is already the sentence to show, so a `.failed` event carries it unchanged.
struct CaptionCaptureError: LocalizedError, Equatable {
    var text: String
    var errorDescription: String? { text }
}

/// What a caption session listens to; tests stand in for the hardware.
struct CaptionCapture: Sendable {
    var requestPermission: @Sendable () async -> Bool
    /// What `.failed` says when `requestPermission` answers no.
    var deniedText: String
    var start: @Sendable (_ onBuffer: @escaping @Sendable ([Float]) -> Void) async throws -> Void
    /// Safe to call after `start` ended or failed; while it runs, the loop calls `interruptStart` instead.
    var stop: @Sendable () -> Void
    /// What a stop does while `start` is still running, when the capture can be cut short then; nil leaves the start to finish first.
    var interruptStart: (@Sendable () -> Void)?
    /// Registers the handler called with the sentence to show if the capture ends by itself; set before `start`, never called after `stop`.
    var whenEnded: (@Sendable (_ handler: @escaping @Sendable (String) -> Void) -> Void)?

    static func microphone(deviceID: DeviceID?) -> CaptionCapture {
        // Capture must not share the cached kit's AudioProcessor: its AVAudioEngine and sample
        // buffer are per-recording state, and another session could be borrowing the same kit.
        nonisolated(unsafe) let processor = AudioProcessor()
        return CaptionCapture(
            requestPermission: { await AudioProcessor.requestRecordPermission() },
            deniedText: FixedFailureText.microphoneNotStarted,
            start: { onBuffer in
                try processor.startRecordingLive(inputDeviceID: deviceID) { buffer in
                    onBuffer(buffer)
                    // Runs on the tap thread, serialized with processBuffer's appends, so this purge can't race them.
                    processor.purgeAudioSamples(keepingLast: 1)
                }
            },
            stop: { processor.stopRecording() },
            interruptStart: nil
        )
    }

    static func live(_ source: CaptionSource, clock: any Clock<Duration>) -> CaptionCapture {
        #if os(macOS)
        switch source {
        case .microphone(let uid):
            return microphone(deviceID: StreamingTranscriptionSession.resolveInputDeviceID(uid: uid))
        case .systemAudio, .app:
            return external(source, environment: .live(clock: clock))
        }
        #else
        return microphone(deviceID: nil)
        #endif
    }
}

#if os(macOS)

/// Whether macOS will let Parola capture, read before anything starts so a refusal never parks a capture.
struct CapturePermissionCheck: Sendable {
    var screenRecordingGranted: @Sendable () -> Bool
    var tapStatus: @Sendable () -> SystemAudioRecordingPermission
    /// Raises the consent dialog and returns once it is answered.
    var probeTapConsent: @Sendable () async -> Void

    static let live = CapturePermissionCheck(
        screenRecordingGranted: { CGPreflightScreenCaptureAccess() },
        tapStatus: { SystemAudioRecordingPermission.current() },
        probeTapConsent: {
            if #available(macOS 14.2, *) { await SystemAudioRecordingPermission.triggerConsentPrompt() }
        }
    )

    func tapAllowed() async -> Bool {
        switch tapStatus() {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            await probeTapConsent()
            return tapStatus() != .denied
        }
    }
}

struct CaptionCaptureEnvironment: Sendable {
    var permissions: CapturePermissionCheck
    var fixtureURL: @Sendable () async -> URL?
    var processObjects: @Sendable (_ bundleID: String) -> [AudioObjectID]
    var makeSystemSource: @Sendable (_ sink: @escaping @Sendable ([Float]) -> Void) -> any LiveAudioSource
    var makeTapSource: @Sendable (_ objects: [AudioObjectID], _ sink: @escaping @Sendable ([Float]) -> Void) throws -> any TargetsGoneReporting
    var startTimeout: Duration
    var clock: any Clock<Duration>
    /// How long the process list gets to settle after a watched process leaves, before the app reads as quit or as still there.
    var endSettle: Duration = .seconds(1)

    static func live(clock: any Clock<Duration>) -> CaptionCaptureEnvironment {
        CaptionCaptureEnvironment(
            permissions: .live,
            fixtureURL: { await MockAudioSourceRegistry.shared.resolve(for: .system) },
            processObjects: { bundleID in
                guard #available(macOS 14.2, *) else { return [] }
                return ProcessTapAudioSource.audioProcessObjects(matching: [bundleID])
            },
            makeSystemSource: { SystemAudioSource(samples: $0) },
            makeTapSource: { objects, sink in
                guard #available(macOS 14.2, *) else { throw ParolaError.captureUnavailable("app audio needs macOS 14.2") }
                return ProcessTapAudioSource(processObjects: objects, samples: sink)
            },
            startTimeout: .seconds(15),
            clock: clock
        )
    }
}

/// A source that can tell its watched processes are gone; only captions ask, so a meeting's `whenCaptureEnds` stays as it was.
protocol TargetsGoneReporting: LiveAudioSource {
    func whenTargetsGone(_ handler: @escaping @Sendable () -> Void) async
}

extension CaptionCapture {
    /// System audio (ScreenCaptureKit) or one app (a process tap), refused or failed with a sentence that names the source.
    static func external(_ source: CaptionSource, environment env: CaptionCaptureEnvironment) -> CaptionCapture {
        let run = ExternalRun()
        let bundleID: String? = if case .app(let id) = source { id } else { nil }
        let fixtureEndText = bundleID.map(FixedFailureText.appQuit) ?? FixedFailureText.systemAudioStopped
        let endText: @Sendable () -> String = {
            guard let bundleID else { return FixedFailureText.systemAudioStopped }
            return env.processObjects(bundleID).isEmpty
                ? FixedFailureText.appQuit(bundleID) : FixedFailureText.appStoppedSending(bundleID)
        }
        let deniedText = bundleID == nil ? FixedFailureText.systemAudioNotAllowed : FixedFailureText.appAudioNotAllowed
        return CaptionCapture(
            requestPermission: {
                if let url = await env.fixtureURL() {
                    run.useFixture(url)
                    return true
                }
                return bundleID == nil ? env.permissions.screenRecordingGranted() : await env.permissions.tapAllowed()
            },
            deniedText: deniedText,
            start: { onBuffer in
                if let url = run.fixtureURL {
                    let fixture = try FixtureCapture(fixtureURL: url, clock: env.clock)
                    guard run.adopt(fixture: fixture) else { return }
                    fixture.start(onBuffer: onBuffer, onEnd: run.endReporter { fixtureEndText })
                    return
                }
                let chunker = SampleRechunker(size: WhisperKit.sampleRate / 10, downstream: onBuffer)
                let sink: @Sendable ([Float]) -> Void = { chunker.append($0) }
                let live: any LiveAudioSource
                var tap: (any TargetsGoneReporting)?
                if let bundleID {
                    let objects = env.processObjects(bundleID)
                    guard !objects.isEmpty else {
                        throw CaptionCaptureError(text: FixedFailureText.appNotPlayingAudio(bundleID))
                    }
                    let made = try env.makeTapSource(objects, sink)
                    tap = made
                    live = made
                } else {
                    live = env.makeSystemSource(sink)
                }
                guard run.adopt(source: live, chunker: chunker) else {
                    await live.cancel()
                    return
                }
                if let tap {
                    await tap.whenTargetsGone(run.endReporter(settleFor: env.endSettle, on: env.clock, endText))
                } else {
                    await live.whenCaptureEnds(run.endReporter(endText))
                }
                try await Self.boundedStart(of: live, run: run, deniedText: deniedText, environment: env)
                if run.isStopped { await live.cancel() }
            },
            stop: { run.stop() },
            interruptStart: { run.stop() },
            whenEnded: { run.onEnded($0) }
        )
    }

    private enum StartResult: Sendable {
        case up, failed(any Error), stopped, timedOut
    }

    /// Waits for the source to come up, for a stop, or for the deadline, whichever is first; a start that ignores all three is left behind and cancelled.
    private static func boundedStart(
        of source: any LiveAudioSource, run: ExternalRun, deniedText: String, environment env: CaptionCaptureEnvironment
    ) async throws {
        let result: StartResult = await withCheckedContinuation { continuation in
            let claimed = OSAllocatedUnfairLock(initialState: false)
            let timer = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
            @Sendable func finish(_ outcome: StartResult) {
                guard claimed.withLock({ taken in
                    defer { taken = true }
                    return !taken
                }) else { return }
                timer.withLock { $0?.cancel() }
                continuation.resume(returning: outcome)
            }
            timer.withLock {
                $0 = Task {
                    guard (try? await env.clock.sleep(for: env.startTimeout)) != nil else { return }
                    finish(.timedOut)
                }
            }
            Task {
                do {
                    try await source.start()
                    finish(.up)
                } catch {
                    finish(.failed(error))
                }
            }
            run.whenStopped { finish(.stopped) }
        }
        switch result {
        case .up:
            return
        case .stopped:
            Task { await source.cancel() }
        case .failed(let error):
            if error is CancellationError { throw error }
            // A refused Screen Recording prompt surfaces as an opaque ScreenCaptureKit error.
            if !(error is CaptionCaptureError), !env.permissions.screenRecordingGranted(), source is SystemAudioSource {
                throw CaptionCaptureError(text: deniedText)
            }
            throw error
        case .timedOut:
            Task { await source.cancel() }
            throw CaptionCaptureError(text: deniedText)
        }
    }
}

/// Regroups a capture's callback-sized buffers into the 100 ms ones the loop's voice detection counts in.
private final class SampleRechunker: Sendable {
    private let size: Int
    private let downstream: @Sendable ([Float]) -> Void
    private let pending = OSAllocatedUnfairLock<[Float]>(initialState: [])

    init(size: Int, downstream: @escaping @Sendable ([Float]) -> Void) {
        self.size = size
        self.downstream = downstream
    }

    // Delivery stays under the lock so a flush can't overtake a chunk another thread has taken out; `downstream` never re-enters this class.
    func append(_ samples: [Float]) {
        pending.withLock { pending in
            pending.append(contentsOf: samples)
            while pending.count >= size {
                downstream(Array(pending.prefix(size)))
                pending.removeFirst(size)
            }
        }
    }

    func flush() {
        pending.withLock { pending in
            if !pending.isEmpty { downstream(pending) }
            pending = []
        }
    }
}

/// One caption run's capture handles; `stop()` may arrive before, during or after `start`.
private final class ExternalRun: Sendable {
    private struct State {
        var fixtureURL: URL?
        var fixture: FixtureCapture?
        var source: (any LiveAudioSource)?
        var chunker: SampleRechunker?
        var stopped = false
        var stopWaiters: [@Sendable () -> Void] = []
        var endHandler: (@Sendable (String) -> Void)?
        var pendingEnd: String?
        var settling: Task<Void, Never>?
        var ended = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var fixtureURL: URL? { state.withLock { $0.fixtureURL } }
    var isStopped: Bool { state.withLock { $0.stopped } }

    func useFixture(_ url: URL) {
        state.withLock { $0.fixtureURL = url }
    }

    /// False when a stop already landed, so the caller starts nothing.
    func adopt(fixture: FixtureCapture) -> Bool {
        state.withLock { state in
            guard !state.stopped else { return false }
            state.fixture = fixture
            return true
        }
    }

    func adopt(source: any LiveAudioSource, chunker: SampleRechunker) -> Bool {
        state.withLock { state in
            guard !state.stopped else { return false }
            state.source = source
            state.chunker = chunker
            return true
        }
    }

    func onEnded(_ handler: @escaping @Sendable (String) -> Void) {
        let pending = state.withLock { state -> String? in
            guard !state.stopped else { return nil }
            guard let pending = state.pendingEnd else {
                state.endHandler = handler
                return nil
            }
            state.pendingEnd = nil
            return pending
        }
        if let pending { handler(pending) }
    }

    /// A callback for a source to hold; it keeps nothing of the run alive.
    func endReporter(
        settleFor settle: Duration? = nil, on clock: (any Clock<Duration>)? = nil, _ text: @escaping @Sendable () -> String
    ) -> @Sendable () -> Void {
        { [weak self] in
            guard let self else { return }
            guard let settle, let clock else { return captureEnded(text()) }
            settleThenEnd(after: settle, on: clock, text)
        }
    }

    private func settleThenEnd(after settle: Duration, on clock: any Clock<Duration>, _ text: @escaping @Sendable () -> String) {
        let waiting = Task { [weak self] in
            guard (try? await clock.sleep(for: settle)) != nil else { return }
            self?.captureEnded(text())
        }
        let accepted = state.withLock { state -> Bool in
            guard !state.stopped, state.settling == nil else { return false }
            state.settling = waiting
            return true
        }
        if !accepted { waiting.cancel() }
    }

    /// Passes `text` to the end handler once, and not at all after a stop.
    func captureEnded(_ text: String) {
        let handler = state.withLock { state -> (@Sendable (String) -> Void)? in
            guard !state.stopped, !state.ended else { return nil }
            state.ended = true
            if state.endHandler == nil { state.pendingEnd = text }
            return state.endHandler
        }
        handler?(text)
    }

    /// Calls `waiter` once the run is stopped, at once if it already is.
    func whenStopped(_ waiter: @escaping @Sendable () -> Void) {
        let stopped = state.withLock { state -> Bool in
            if !state.stopped { state.stopWaiters.append(waiter) }
            return state.stopped
        }
        if stopped { waiter() }
    }

    func stop() {
        let (fixture, source, chunker, waiters) = state.withLock { state in
            state.stopped = true
            state.endHandler = nil
            state.settling?.cancel()
            defer { state.stopWaiters = [] }
            return (state.fixture, state.source, state.chunker, state.stopWaiters)
        }
        chunker?.flush()
        fixture?.stop()
        if let source { Task { await source.cancel() } }
        for waiter in waiters { waiter() }
    }
}

#endif
