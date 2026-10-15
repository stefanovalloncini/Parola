import Foundation
import os

/// One result from Apple's analyzer: volatile until the analyzer settles on it.
struct CaptionRecognition: Sendable, Equatable {
    /// A stretch of `text` with the audio time the analyzer gave it, when it gave one.
    struct Run: Sendable, Equatable {
        var text: String
        var start: Double?
        var end: Double?
    }

    var text: String
    var start: Double
    var end: Double
    var isFinal: Bool
    var runs: [Run] = []
}

/// A running analyzer, behind a seam so the session's rules can be tested without the system's speech model.
protocol CaptionAnalyzing: Sendable {
    var recognitions: AsyncThrowingStream<CaptionRecognition, any Error> { get }
    /// Takes the capture's 16 kHz mono chunks; safe to call from the capture thread.
    func feed(_ samples: [Float])
    /// Ends the input and settles what the analyzer still holds; `recognitions` finishes afterwards.
    func finalize() async throws
    func cancel() async
}

struct AppleSpeechCaptionBackend: Sendable {
    /// Resolves `locale` to one Speech supports and installs its assets, reporting progress as a fraction.
    var prepare: @Sendable (_ locale: Locale, _ progress: @escaping @Sendable (Double) -> Void) async throws -> Locale
    var makeAnalyzer: @Sendable (_ locale: Locale) async throws -> any CaptionAnalyzing
}

extension AppleSpeechCaptionBackend {
    static let offline = AppleSpeechCaptionBackend(
        prepare: { _, _ in throw LiveSpeechCaption.startFailed },
        makeAnalyzer: { _ in throw LiveSpeechCaption.startFailed }
    )
}

/// Live Captions on Apple Speech: the analyzer does its own windowing, so this session feeds it the capture and maps its results.
actor AppleSpeechCaptionSession: StreamingTranscriber {
    typealias CaptureFor = @Sendable (CaptionSource) -> CaptionCapture

    nonisolated let source: CaptionSource
    nonisolated let levelMeter = LevelMeter()

    private enum Phase { case idle, preparing, running, ending, done }
    private enum PendingEnd { case stop, cancel }

    private let backend: AppleSpeechCaptionBackend
    private let captureFor: CaptureFor
    private let settleGate: SettleGate
    private let settleLimit: Duration
    private let clock: any Clock<Duration>
    private let intake = Intake()

    private var phase = Phase.idle
    private var pendingEnd: PendingEnd?
    private var preparing: Task<Locale, any Error>?
    private var runTask: Task<Void, Never>?
    private var collector: Task<Void, Never>?
    private var analyzer: (any CaptionAnalyzing)?
    private var capture: CaptionCapture?
    private var startingCapture = false
    private var didStopCapture = false
    private var creatingAnalyzer = false
    private var holdingGateForCreation = false
    private var settling: FirstResult<Bool>?
    private var cancelledWhileEnding = false
    private var continuation: AsyncStream<StreamingEvent>.Continuation?
    private var confirmed: [TranscriptSegment] = []
    private var lastPartial = ""
    private var options = TranscriptionOptions()
    private var locale = Locale(identifier: "en_US")

    init(
        source: CaptionSource,
        backend: AppleSpeechCaptionBackend = .live,
        capture: CaptureFor? = nil,
        settleGate: SettleGate = .shared,
        clock: any Clock<Duration> = ContinuousClock(),
        settleLimit: Duration = .seconds(5)
    ) {
        self.settleLimit = settleLimit
        self.clock = clock
        self.source = source
        self.backend = backend
        self.captureFor = capture ?? { CaptionCapture.live($0, clock: clock) }
        self.settleGate = settleGate
    }

    static func admit(_ options: TranscriptionOptions) throws {
        if options.task == .translate {
            ParolaLog.notice(.streaming, "rejected translate: unsupported")
            throw ParolaError.unsupportedForEngine(FixedFailureText.cannotTranslate("Apple Speech"))
        }
    }

    func start(
        options: TranscriptionOptions,
        speakerLabeler: (any StreamingSpeakerLabeler)? = nil,
        downloadProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AsyncStream<StreamingEvent> {
        guard phase == .idle else {
            ParolaLog.fault(.streaming, "start called while a session was already running")
            throw ParolaError.transcriptionFailed("session already started")
        }
        try Self.admit(options)
        self.options = options
        phase = .preparing
        pendingEnd = nil
        ParolaLog.info(.streaming, "streaming session starting on apple speech")

        let requested = AppleSpeechTranscriber.pickLocale(language: options.language)
        let preparing = Task { [backend] in
            try await backend.prepare(requested) { downloadProgress?($0) }
        }
        self.preparing = preparing
        let prepared: Result<Locale, any Error> = await withTaskCancellationHandler {
            await preparing.result
        } onCancel: {
            preparing.cancel()
        }
        self.preparing = nil

        let end = Task.isCancelled ? PendingEnd.cancel : pendingEnd
        pendingEnd = nil
        switch end {
        case .cancel?:
            phase = .done
            throw CancellationError()
        case .stop?:
            phase = .done
            return Self.endedBeforeCapture(options: options)
        case nil:
            break
        }
        switch prepared {
        case .failure(let error):
            phase = .done
            throw error
        case .success(let resolved):
            locale = resolved
        }

        let (stream, continuation) = AsyncStream<StreamingEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        self.continuation = continuation
        let capture = captureFor(source)
        self.capture = capture
        phase = .running
        runTask = Task { await self.run(capture: capture) }
        return stream
    }

    private static func endedBeforeCapture(options: TranscriptionOptions) -> AsyncStream<StreamingEvent> {
        let (stream, continuation) = AsyncStream<StreamingEvent>.makeStream()
        continuation.yield(.finished(Transcript(
            segments: [], language: options.language ?? "auto", modelName: AppleSpeechTranscriber.syntheticModelID
        )))
        continuation.finish()
        return stream
    }

    private func run(capture: CaptionCapture) async {
        guard await capture.requestPermission() else {
            await fail(capture.deniedText)
            return
        }
        guard phase == .running else { return }
        await settleGate.waitUntilSettled()
        guard phase == .running else { return }

        let made: any CaptionAnalyzing
        creatingAnalyzer = true
        do {
            made = try await backend.makeAnalyzer(locale)
        } catch {
            creatingAnalyzer = false
            endCreationHold()
            ParolaLog.error(.streaming, "apple speech analyzer failed to start", [.error: .error(error)])
            await fail((error as? ParolaError)?.errorDescription ?? FixedFailureText.appleSpeechCouldNotStart)
            return
        }
        creatingAnalyzer = false
        guard phase == .running else {
            await made.cancel()
            endCreationHold()
            return
        }
        analyzer = made
        intake.open(analyzer: made, meter: levelMeter)
        collector = Task { [weak self] in
            do {
                for try await recognition in made.recognitions { await self?.apply(recognition) }
                Task { await self?.recognitionsEnded() }
            } catch {
                // Failing awaits this very task, so it has to end first.
                Task { await self?.recognitionFailed(error) }
            }
        }
        capture.whenEnded? { [weak self] text in
            Task { await self?.captureEnded(text) }
        }

        startingCapture = true
        do {
            try await capture.start { [intake] samples in intake.take(samples) }
        } catch {
            startingCapture = false
            ParolaLog.error(.streaming, "streaming capture failed to start", [.error: .error(error)])
            stopCapture()
            if phase == .running { await fail(error.localizedDescription) }
            return
        }
        startingCapture = false
        if phase != .running { stopCapture() }
    }

    private func apply(_ recognition: CaptionRecognition) {
        guard phase == .running || phase == .ending else { return }
        let text = recognition.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            clearPartial()
            return
        }
        guard recognition.isFinal else {
            guard text != lastPartial else { return }
            lastPartial = text
            continuation?.yield(.partial(text: text))
            return
        }
        lastPartial = ""
        for piece in CaptionSentences.split(recognition) {
            let segment = TranscriptSegment(
                id: confirmed.count, start: piece.start, end: piece.end,
                text: piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            confirmed.append(segment)
            continuation?.yield(.confirmed(segment))
        }
    }

    private func clearPartial() {
        guard !lastPartial.isEmpty else { return }
        lastPartial = ""
        continuation?.yield(.partial(text: ""))
    }

    private func recognitionsEnded() async {
        guard phase == .running else { return }
        ParolaLog.error(.streaming, "apple speech results ended without a stop")
        await fail(FixedFailureText.appleSpeechStoppedListening)
    }

    private func recognitionFailed(_ error: any Error) async {
        guard phase == .running else { return }
        ParolaLog.error(.streaming, "apple speech results failed", [.error: .error(error)])
        await fail(error.localizedDescription)
    }

    /// The capture ended by itself: what the analyzer holds is settled first, then the run fails with the reason.
    private func captureEnded(_ text: String) async {
        guard phase == .running else { return }
        phase = .ending
        interruptCapture()
        await settle()
        if !cancelledWhileEnding { continuation?.yield(.failed(text)) }
        finishStream()
    }

    private func fail(_ text: String) async {
        guard phase == .running else { return }
        phase = .ending
        interruptCapture()
        await discard()
        continuation?.yield(.failed(text))
        finishStream()
    }

    func stop() async {
        switch phase {
        case .preparing:
            if pendingEnd == nil { pendingEnd = .stop }
            preparing?.cancel()
        case .running:
            phase = .ending
            holdGateWhileCreating()
            interruptCapture()
            if startingCapture { await runTask?.value }
            stopCapture()
            await settle()
            if !cancelledWhileEnding { continuation?.yield(.finished(await finishedTranscript())) }
            finishStream()
        case .ending:
            break
        case .idle, .done:
            break
        }
    }

    func cancel() async {
        switch phase {
        case .preparing:
            pendingEnd = .cancel
            preparing?.cancel()
        case .running:
            phase = .ending
            holdGateWhileCreating()
            interruptCapture()
            runTask?.cancel()
            if startingCapture { await runTask?.value }
            stopCapture()
            await discard()
            finishStream()
        case .ending:
            cancelledWhileEnding = true
            settling?.resolve(false)
        case .idle, .done:
            break
        }
    }

    func setPaused(_ paused: Bool) async {
        intake.setPaused(paused)
    }

    func currentModel() -> String? { AppleSpeechTranscriber.syntheticModelID }

    /// Held words become final. A finalize that fails, hangs past the limit or is cancelled leaves the analyzer cancelled and the held words kept as a line.
    private func settle() async {
        guard let analyzer else { return }
        intake.close()
        let race = FirstResult<Bool>()
        settling = race
        if cancelledWhileEnding { race.resolve(false) }
        let limit = settleLimit
        let clock = clock
        Task {
            let finalized = await AsyncTimeout.run(limit, clock: clock) { () async -> Bool in
                do {
                    try await analyzer.finalize()
                    return true
                } catch {
                    ParolaLog.error(.streaming, "apple speech failed to finalize", [.error: .error(error)])
                    return false
                }
            }
            race.resolve(finalized ?? false)
        }
        let settled = await race.wait()
        settling = nil
        if !settled { await analyzer.cancel() }
        await collector?.value
        if !settled, !cancelledWhileEnding { keepHeldWords() }
    }

    private func keepHeldWords() {
        guard !lastPartial.isEmpty else { return }
        let at = confirmed.last?.end ?? 0
        apply(CaptionRecognition(text: lastPartial, start: at, end: at, isFinal: true))
    }

    /// A late analyzer is cancelled after the stop returns, so the gate stays shut until then.
    private func holdGateWhileCreating() {
        guard creatingAnalyzer, !holdingGateForCreation else { return }
        holdingGateForCreation = true
        settleGate.beginStop()
    }

    private func endCreationHold() {
        guard holdingGateForCreation else { return }
        holdingGateForCreation = false
        settleGate.endStop()
    }

    private func discard() async {
        intake.close()
        collector?.cancel()
        await analyzer?.cancel()
        await collector?.value
    }

    private func finishedTranscript() async -> Transcript {
        var stamped = options
        stamped.language = options.language ?? locale.language.languageCode?.identifier
        return await StreamingTranscriptionSession.finishedTake(
            segments: confirmed, options: stamped, modelName: AppleSpeechTranscriber.syntheticModelID, audioURL: nil,
            engine: .appleSpeech
        )
    }

    private func interruptCapture() {
        if startingCapture {
            capture?.interruptStart?()
        } else {
            stopCapture()
        }
    }

    private func stopCapture() {
        guard !didStopCapture, let capture else { return }
        didStopCapture = true
        capture.stop()
    }

    private func finishStream() {
        continuation?.finish()
        continuation = nil
        collector = nil
        analyzer = nil
        capture = nil
        runTask = nil
        levelMeter.reset()
        phase = .done
    }
}

/// What the capture thread hands the analyzer: gated by pause and by the session's end.
private final class Intake: Sendable {
    private struct State {
        var analyzer: (any CaptionAnalyzing)?
        var meter: LevelMeter?
        var paused = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func open(analyzer: any CaptionAnalyzing, meter: LevelMeter) {
        state.withLock {
            $0.analyzer = analyzer
            $0.meter = meter
        }
    }

    func close() {
        state.withLock { $0.analyzer = nil }
    }

    func setPaused(_ paused: Bool) {
        state.withLock { $0.paused = paused }
    }

    func take(_ samples: [Float]) {
        let (analyzer, meter, paused) = state.withLock { ($0.analyzer, $0.meter, $0.paused) }
        guard let analyzer, !paused, !samples.isEmpty else { return }
        var sumSquares: Float = 0
        for sample in samples { sumSquares += sample * sample }
        meter?.record(AudioLevel.normalised(rms: (sumSquares / Float(samples.count)).squareRoot()))
        analyzer.feed(samples)
    }
}
