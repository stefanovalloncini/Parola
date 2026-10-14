import Foundation
import os
@preconcurrency import WhisperKit

struct ConfirmedAudioBatch: Sendable {
    var segments: [TranscriptionSegment]
    var audioWindow: [Float]
    var windowStartSeconds: Double
}

/// Replaces WhisperKit's AudioStreamTranscriber with a loop that keeps only unconfirmed audio; emitted timestamps stay absolute.
actor StreamingRealtimeLoop {
    struct Configuration: Sendable {
        var requiredSegmentsForConfirmation = 2
        var silenceThreshold: Float = 0.3
        var compressionCheckWindow = 60
        var useVAD = true
        var purgePadSeconds: Double = 2
        var maxWindowSeconds: Double = 60
        var sampleRate = WhisperKit.sampleRate
        var wantsConfirmedAudio = false
        /// A stop during the model load waits for the model and decodes what was captured; without it the stop drops that audio.
        var waitsForModelOnStop = false
        /// How long such a stop waits before it gives up on the words; the take keeps its audio.
        var maxModelWaitOnStop: Duration = .seconds(120)
        /// How far held audio may run past `maxWindowSeconds` during the model load before it's cut back, so the cut isn't paid per buffer.
        var preModelSlackSeconds: Double = 5
        /// A segment ending this long before the end of the decoded window is confirmed even while held back. Nil leaves confirmation to the holdback alone.
        var forceConfirmAfterSeconds: Double?
        /// A decode never starts earlier than this long before the end of the window. Nil decodes from the oldest unconfirmed audio.
        var maxDecodeSeconds: Double?
        /// A decode that starts inside the word a forced cut ended on hears its tail again; this drops that repeat from the new text.
        var dropsWordRepeatedAtCut = false
        /// A decode starts this far before the first held-back segment instead of at the confirmed end. Nil starts at the confirmed end.
        var heldSegmentBackoffSeconds: Double?
        /// How much audio must arrive since the last decode before the next one runs.
        var minNewAudioSeconds: Double = 1
    }

    typealias Transcribe = @Sendable ([Float], DecodingOptions, @escaping TranscriptionCallback) async throws -> TranscriptionResult

    struct Decoder: Sendable {
        var options: DecodingOptions
        var transcribe: Transcribe
    }

    struct Dependencies: Sendable {
        enum Model: Sendable {
            case ready(Transcribe)
            /// Loads once capture is up; decodes wait for it and use the options it brings.
            case loading(@Sendable () async throws -> Decoder)
        }

        var requestPermission: @Sendable () async -> Bool
        /// The callback's Bool reports whether it took the buffer, so a caller can gate another consumer on the same decision.
        var startCapture: @Sendable (@escaping @Sendable ([Float]) -> Bool) async throws -> Void
        var stopCapture: @Sendable () -> Void
        /// Called instead of `stopCapture` when a stop lands while `startCapture` is still running, so a start that can be cut short is.
        var interruptStart: (@Sendable () -> Void)?
        var model: Model
        var tick: @Sendable () async throws -> Void

        init(
            requestPermission: @escaping @Sendable () async -> Bool,
            startCapture: @escaping @Sendable (@escaping @Sendable ([Float]) -> Bool) async throws -> Void,
            stopCapture: @escaping @Sendable () -> Void,
            interruptStart: (@Sendable () -> Void)? = nil,
            transcribe: @escaping Transcribe,
            tick: @escaping @Sendable () async throws -> Void
        ) {
            self.init(
                requestPermission: requestPermission, startCapture: startCapture, stopCapture: stopCapture,
                interruptStart: interruptStart, model: .ready(transcribe), tick: tick
            )
        }

        init(
            requestPermission: @escaping @Sendable () async -> Bool,
            startCapture: @escaping @Sendable (@escaping @Sendable ([Float]) -> Bool) async throws -> Void,
            stopCapture: @escaping @Sendable () -> Void,
            interruptStart: (@Sendable () -> Void)? = nil,
            model: Model,
            tick: @escaping @Sendable () async throws -> Void
        ) {
            self.requestPermission = requestPermission
            self.startCapture = startCapture
            self.stopCapture = stopCapture
            self.interruptStart = interruptStart
            self.model = model
            self.tick = tick
        }
    }

    enum Outcome: Sendable {
        case stopped
        case cancelled
        case permissionDenied
        case failed(any Error)
        /// Capture was up when the model failed to load, so nothing was decoded.
        case modelFailed(any Error)
        /// A stop gave up waiting for the model, so the take has its audio and no transcript.
        case stoppedWithoutModel
    }

    /// While the model loads, pending audio past `trimAbove` samples is cut back to its newest `keep`.
    private struct PendingLimit: Sendable {
        var keep: Int
        var trimAbove: Int
    }

    private struct StopSignal: Sendable {
        var requested = false
        var interruptsDecode: Bool?
        var interruptedDecode = false
    }

    private struct Inbox: Sendable {
        var pending: [Float] = []
        var energies: [(rel: Float, avg: Float, samples: Int)] = []
        var limit: PendingLimit?
        var dropped = 0
    }

    // Trimming old entries is safe: VAD only reads a recent suffix (baseline over the last 20, voice check over the new-audio span).
    private static let maxEnergyEntries = 4096
    private static let waitingForSpeech = "Waiting for speech..."

    /// Yields once decodes can run and finishes then, or as the run ends without them: a caller waits on it for the model.
    nonisolated let decoderReady: AsyncStream<Void>

    private let config: Configuration
    private let baseDecodingOptions: DecodingOptions
    private let deps: Dependencies
    private let onPartial: @Sendable (String) -> Void
    private let onEnergy: @Sendable (Float) -> Void
    private let onConfirmed: @Sendable (ConfirmedAudioBatch) -> Void
    private let levelMeter: LevelMeter
    private let inbox: OSAllocatedUnfairLock<Inbox>
    private let paused = OSAllocatedUnfairLock(initialState: false)
    private let stopSignal = OSAllocatedUnfairLock(initialState: StopSignal())
    private let decoderReadySignal: AsyncStream<Void>.Continuation
    private let clock: any Clock<Duration>

    private var window: [Float] = []
    private var windowStartSample = 0
    private var lastTranscribedTotal = 0
    private var lastConfirmedEndSeconds: Float = 0
    private var unconfirmedSegments: [TranscriptionSegment] = []
    private var currentText = ""
    private var lastConfirmedWord: String?
    private var lastConfirmedEndedSentence = false
    private var isRunning = false
    private var didStopCapture = false
    private var startingCapture = false
    private var stopRequested = false
    private var flushesOnStop = true
    private var permissionWait: CheckedContinuation<Bool?, Never>?
    private var modelLoad: Task<Decoder, any Error>?
    private var modelWaitLimit: Task<Void, Never>?
    private var gaveUpOnModel = false
    private var interruptedTotal: Int?

    /// `decodingOptions` go with a ready `transcribe`; a model that loads brings its own.
    init(
        configuration: Configuration,
        decodingOptions: DecodingOptions = DecodingOptions(),
        dependencies: Dependencies,
        levelMeter: LevelMeter = LevelMeter(),
        clock: any Clock<Duration> = ContinuousClock(),
        onPartial: @escaping @Sendable (String) -> Void,
        onEnergy: @escaping @Sendable (Float) -> Void,
        onConfirmed: @escaping @Sendable (ConfirmedAudioBatch) -> Void
    ) {
        self.config = configuration
        self.clock = clock
        self.baseDecodingOptions = decodingOptions
        self.deps = dependencies
        self.onPartial = onPartial
        self.onEnergy = onEnergy
        self.onConfirmed = onConfirmed
        self.levelMeter = levelMeter
        var inbox = Inbox()
        if case .loading = dependencies.model {
            let sampleRate = Double(configuration.sampleRate)
            // No decode keeps more than maxWindowSeconds, so older audio held for the model would only be dropped later.
            inbox.limit = PendingLimit(
                keep: Int(configuration.maxWindowSeconds * sampleRate),
                trimAbove: Int((configuration.maxWindowSeconds + configuration.preModelSlackSeconds) * sampleRate)
            )
        }
        self.inbox = OSAllocatedUnfairLock(initialState: inbox)
        (decoderReady, decoderReadySignal) = AsyncStream.makeStream()
    }

    func run() async -> Outcome {
        defer { decoderReadySignal.finish() }
        guard let granted = await permission() else { return .stopped }
        guard granted else {
            ParolaLog.notice(.streaming, "microphone permission denied")
            return .permissionDenied
        }
        // stop() can land while the first-run prompt is up; Allow must not bring up a mic nobody can stop.
        guard !stopRequested else { return .stopped }
        let startedAt = ContinuousClock.now
        startingCapture = true
        do {
            try await deps.startCapture { [weak self] buffer in self?.ingest(buffer) ?? false }
        } catch {
            startingCapture = false
            ParolaLog.error(.streaming, "streaming capture failed to start", [.error: .error(error)])
            stopCapture()
            guard !stopRequested else { return .stopped }
            return .failed(error)
        }
        startingCapture = false
        // A stop that landed during the start only interrupted it, so whatever came up is stopped now.
        guard !stopRequested else {
            stopCapture()
            return .stopped
        }
        isRunning = true
        let decoder: Decoder
        switch deps.model {
        case .ready(let transcribe):
            decoder = Decoder(options: baseDecodingOptions, transcribe: transcribe)
        case .loading(let load):
            markWaitingForSpeech()
            let loaded = await loadedModel(load)
            guard isRunning || (flushesOnStop && config.waitsForModelOnStop) else {
                return flushesOnStop ? .stopped : .cancelled
            }
            switch loaded {
            case .success(let ready):
                decoder = ready
            case .failure(let error):
                isRunning = false
                stopCapture()
                if Task.isCancelled { return .cancelled }
                return gaveUpOnModel ? .stoppedWithoutModel : .modelFailed(error)
            }
        }
        decoderReadySignal.yield()
        decoderReadySignal.finish()
        while isRunning {
            do {
                try await iterate(with: decoder)
            } catch is CancellationError {
                isRunning = false
                stopCapture()
                return .cancelled
            } catch {
                ParolaLog.error(
                    .streaming, "streaming iteration failed",
                    [.elapsed: .duration(startedAt.duration(to: .now)), .error: .error(error)]
                )
                isRunning = false
                stopCapture()
                guard stopRequested, flushesOnStop else { return .failed(error) }
            }
        }
        guard flushesOnStop else { return .cancelled }
        // Runs on this task, never from stop(): a flush entering the actor mid-iterate
        // would race the in-flight decode on the shared TranscribeTask.
        await finalFlush(with: decoder)
        // A cancel that lands during the flush still discards the take.
        return flushesOnStop ? .stopped : .cancelled
    }

    /// Waits for the model while capture fills the inbox; a stop or a cancel cancels the load.
    private func loadedModel(_ load: @escaping @Sendable () async throws -> Decoder) async -> Result<Decoder, any Error> {
        let loading = Task { try await load() }
        modelLoad = loading
        let result = await withTaskCancellationHandler {
            await loading.result
        } onCancel: {
            loading.cancel()
        }
        modelLoad = nil
        modelWaitLimit?.cancel()
        modelWaitLimit = nil
        takeAudioHeldForModel()
        return result
    }

    private func limitModelWait() {
        guard modelLoad != nil, modelWaitLimit == nil else { return }
        let limit = config.maxModelWaitOnStop
        modelWaitLimit = Task { [clock] in
            try? await Task.sleep(for: limit, clock: clock)
            if Task.isCancelled { return }
            self.giveUpOnModel()
        }
    }

    private func giveUpOnModel() {
        guard let modelLoad else { return }
        gaveUpOnModel = true
        ParolaLog.notice(
            .streaming, "a stopped take gave up waiting for its model", [.elapsed: .duration(config.maxModelWaitOnStop)]
        )
        modelLoad.cancel()
    }

    /// Moves what capture held during the load into the window and lets go of the room it took.
    private func takeAudioHeldForModel() {
        let (held, dropped) = inbox.withLock { box -> ([Float], Int) in
            let taken = (box.pending, box.dropped)
            box.pending = []
            box.dropped = 0
            box.limit = nil
            return taken
        }
        if dropped > 0 {
            ParolaLog.notice(
                .streaming, "the model load outlasted the audio buffer, so its oldest audio was dropped",
                [.audioSeconds: .seconds(Double(dropped) / Double(config.sampleRate))]
            )
        }
        windowStartSample += dropped
        lastTranscribedTotal = max(lastTranscribedTotal, windowStartSample)
        window.append(contentsOf: held)
    }

    /// Decodes audio that arrived after the last iteration — the 1-second cadence gate
    /// would otherwise drop the user's final word at stop — and promotes whatever ends
    /// up unconfirmed: with no further audio coming, the last hypothesis is final.
    private func finalFlush(with decoder: Decoder) async {
        drainInbox()
        if let interruptedTotal {
            await flushAfterInterrupt(at: interruptedTotal, with: decoder)
        } else {
            enforceWindowCap()
            let totalSamples = windowStartSample + window.count
            let newSeconds = Float(totalSamples - lastTranscribedTotal) / Float(config.sampleRate)
            if newSeconds > 0.05, voiceDetectedInTail(newSeconds) {
                lastTranscribedTotal = totalSamples
                _ = try? await transcribeWindow(with: decoder, confirmAll: true)
            }
        }
        guard !unconfirmedSegments.isEmpty else { return }
        if let last = unconfirmedSegments.last, last.end > lastConfirmedEndSeconds {
            lastConfirmedEndSeconds = last.end
        }
        confirm(makeBatch(unconfirmedSegments))
        unconfirmedSegments = []
    }

    /// The decode a stop cut short saw `interruptedTotal` samples; a silent tail after them leaves it the same input, so the result matches a stop that waited for it.
    private func flushAfterInterrupt(at interruptedTotal: Int, with decoder: Decoder) async {
        let totalSamples = windowStartSample + window.count
        let tailSeconds = Float(totalSamples - interruptedTotal) / Float(config.sampleRate)
        let tailHasVoice = tailSeconds > 0.05 && voiceDetectedInTail(tailSeconds)
        let decodedCount = tailHasVoice ? window.count : max(0, interruptedTotal - windowStartSample)
        lastTranscribedTotal = windowStartSample + decodedCount
        _ = try? await transcribeWindow(with: decoder, samples: Array(window.prefix(decodedCount)), confirmAll: true)
    }

    // Mirrors iterate()'s gate so a silent tail (VAD held it back all along) isn't
    // suddenly decoded at stop — Whisper hallucinates on long silence.
    private func voiceDetectedInTail(_ newSeconds: Float) -> Bool {
        guard config.useVAD else { return true }
        return voiceDetected(inNext: newSeconds, wholeSpan: true)
    }

    /// Decided once, when the stop first shows during a decode: it is cut short only if the audio that arrived since the decode began holds speech, as the flush must decode that anyway; a silent tail lets the decode finish and be promoted.
    nonisolated private func stopInterruptsDecode() -> Bool {
        let (requested, decided) = stopSignal.withLock { ($0.requested, $0.interruptsDecode) }
        guard requested else { return false }
        if let decided { return decided }
        let tailSamples = inbox.withLock { $0.pending.count }
        let tailSeconds = Float(tailSamples) / Float(config.sampleRate)
        let interrupts = tailSeconds > 0.05 && (!config.useVAD || voiceDetected(inNext: tailSeconds, wholeSpan: true))
        stopSignal.withLock { $0.interruptsDecode = interrupts }
        return interrupts
    }

    private static let minimumStopVoiceSeconds: Float = 0.2

    /// `wholeSpan` is for the stop: isVoiceDetected ignores the newest second of a span over two seconds, where a last word sits; it wants 0.2 s of unbroken voiced buffers so the Stop click alone does not count.
    nonisolated private func voiceDetected(inNext seconds: Float, wholeSpan: Bool = false) -> Bool {
        if wholeSpan { return voicedRunLongEnough(inLast: seconds) }
        let considered = max(0, Int(seconds / 0.1))
        let energies = inbox.withLock { $0.energies.suffix(considered).map(\.rel) }
        return AudioProcessor.isVoiceDetected(
            in: energies,
            nextBufferInSeconds: seconds,
            silenceThreshold: config.silenceThreshold
        )
    }

    nonisolated private func voicedRunLongEnough(inLast seconds: Float) -> Bool {
        let covered = Int((seconds * Float(config.sampleRate)).rounded(.up))
        let needed = Int(Self.minimumStopVoiceSeconds * Float(config.sampleRate))
        return inbox.withLock { box in
            var seen = 0
            var run = 0
            for entry in box.energies.reversed() where seen < covered {
                seen += entry.samples
                run = entry.rel > config.silenceThreshold ? run + entry.samples : 0
                if run >= needed { return true }
            }
            return false
        }
    }

    func stop() {
        stopRequested = true
        isRunning = false
        if flushesOnStop { stopSignal.withLock { $0.requested = true } }
        if flushesOnStop && config.waitsForModelOnStop {
            limitModelWait()
        } else {
            modelLoad?.cancel()
        }
        if startingCapture {
            deps.interruptStart?()
        } else {
            stopCapture()
        }
        answerPermission(nil)
    }

    /// An unanswered microphone prompt never calls back, so a stop stops waiting for it; nil means the stop came first.
    private func permission() async -> Bool? {
        guard !stopRequested else { return nil }
        let request = deps.requestPermission
        return await withCheckedContinuation { continuation in
            permissionWait = continuation
            Task {
                let granted = await request()
                self.answerPermission(granted)
            }
        }
    }

    private func answerPermission(_ granted: Bool?) {
        permissionWait?.resume(returning: granted)
        permissionWait = nil
    }

    func cancel() {
        flushesOnStop = false
        stop()
    }

    private func stopCapture() {
        guard !didStopCapture else { return }
        didStopCapture = true
        deps.stopCapture()
    }

    func windowSampleCount() -> Int { window.count }

    func windowStartOffsetSamples() -> Int { windowStartSample }

    nonisolated func pendingSampleCount() -> Int { inbox.withLock { $0.pending.count } }

    nonisolated func setPaused(_ value: Bool) {
        paused.withLock { $0 = value }
    }

    nonisolated private func ingest(_ buffer: [Float]) -> Bool {
        guard !buffer.isEmpty, !paused.withLock({ $0 }) else { return false }
        let avgEnergy = AudioProcessor.calculateEnergy(of: buffer).avg
        levelMeter.record(AudioLevel.normalised(rms: avgEnergy))
        let baseline = inbox.withLock { box -> Float in
            var lowest = Float.infinity
            for entry in box.energies.suffix(20) { lowest = min(lowest, entry.avg) }
            return lowest
        }
        let rel = AudioProcessor.calculateRelativeEnergy(of: buffer, relativeTo: baseline)
        inbox.withLock { box in
            box.pending.append(contentsOf: buffer)
            if let limit = box.limit, box.pending.count > limit.trimAbove {
                let excess = box.pending.count - limit.keep
                box.pending.removeFirst(excess)
                box.dropped += excess
            }
            box.energies.append((rel: rel, avg: avgEnergy, samples: buffer.count))
            if box.energies.count > Self.maxEnergyEntries {
                box.energies.removeFirst(box.energies.count - Self.maxEnergyEntries)
            }
        }
        onEnergy(rel)
        return true
    }

    private func iterate(with decoder: Decoder) async throws {
        drainInbox()
        enforceWindowCap()
        let totalSamples = windowStartSample + window.count
        let newSamples = totalSamples - lastTranscribedTotal
        let newSeconds = Float(newSamples) / Float(config.sampleRate)
        guard newSamples >= Int((config.minNewAudioSeconds * Double(config.sampleRate)).rounded()) else {
            markWaitingForSpeech()
            return try await deps.tick()
        }
        if config.useVAD, !voiceDetected(inNext: newSeconds) {
            markWaitingForSpeech()
            return try await deps.tick()
        }
        let previousTotal = lastTranscribedTotal
        lastTranscribedTotal = totalSamples
        do {
            if try await transcribeWindow(with: decoder, yieldsToFinalFlush: true) {
                interruptedTotal = totalSamples
                lastTranscribedTotal = previousTotal
            }
        } catch {
            if stopRequested { lastTranscribedTotal = previousTotal }
            throw error
        }
    }

    private func drainInbox() {
        let pending = inbox.withLock { box -> [Float] in
            let drained = box.pending
            box.pending.removeAll(keepingCapacity: true)
            return drained
        }
        window.append(contentsOf: pending)
    }

    // Audio still unconfirmed after maxWindowSeconds could only confirm with unbounded latency; dropping it keeps the eventual decode bounded when speech resumes.
    private func enforceWindowCap() {
        let excess = window.count - Int(config.maxWindowSeconds * Double(config.sampleRate))
        guard excess > 0 else { return }
        window.removeFirst(excess)
        windowStartSample += excess
        lastTranscribedTotal = max(lastTranscribedTotal, windowStartSample)
    }

    // The watermark can sit past a retained segment's start when timestamps regress; the next decode and the purge both have to stay behind whichever comes first.
    private var retainedFloorSeconds: Double {
        let retainedStart = unconfirmedSegments.map { Double($0.start) }.min() ?? .greatestFiniteMagnitude
        return min(Double(lastConfirmedEndSeconds), retainedStart)
    }

    /// True when a stop cut the decode short and its result was dropped.
    @discardableResult
    private func transcribeWindow(
        with decoder: Decoder,
        samples: [Float]? = nil,
        confirmAll: Bool = false,
        yieldsToFinalFlush: Bool = false
    ) async throws -> Bool {
        let decoded = samples ?? window
        let offsetSeconds = Double(windowStartSample) / Double(config.sampleRate)
        let decodedEndSeconds = Float(offsetSeconds + Double(decoded.count) / Double(config.sampleRate))
        confirmStaleSegments(decodedEnd: Double(decodedEndSeconds))
        let clipSeconds = decodeFloorSeconds(decodedEnd: Double(decodedEndSeconds))
        var options = decoder.options
        // clipTimestamps is window-relative; everything emitted from here back out must be absolute.
        options.clipTimestamps = [Float(max(0, clipSeconds - offsetSeconds))]
        let emitProgressPartials = unconfirmedSegments.isEmpty
        let onPartial = self.onPartial
        let compressionCheckWindow = config.compressionCheckWindow
        let stopSignal = self.stopSignal
        let result = try await decoder.transcribe(decoded, options) { [options] progress in
            if yieldsToFinalFlush, self.stopInterruptsDecode() {
                stopSignal.withLock { $0.interruptedDecode = true }
                return false
            }
            if emitProgressPartials {
                onPartial(progress.text.trimmingCharacters(in: .whitespaces))
            }
            return Self.shouldStopEarly(
                progress: progress,
                options: options,
                compressionCheckWindow: compressionCheckWindow
            )
        }
        if yieldsToFinalFlush, stopSignal.withLock({ $0.interruptedDecode }) {
            return true
        }
        currentText = ""
        let offset = Float(offsetSeconds)
        var segments = result.segments.map { segment -> TranscriptionSegment in
            var shifted = segment
            shifted.start += offset
            shifted.end += offset
            shifted.words = shifted.words?.map { word in
                var shiftedWord = word
                shiftedWord.start += offset
                shiftedWord.end += offset
                return shiftedWord
            }
            return shifted
        }
        if config.dropsWordRepeatedAtCut { dropWordRepeatedAtCut(from: &segments, decodeStart: clipSeconds) }
        if confirmAll {
            if let last = segments.last, last.end > lastConfirmedEndSeconds {
                lastConfirmedEndSeconds = last.end
            }
            if !segments.isEmpty {
                confirm(makeBatch(segments))
            }
            unconfirmedSegments = []
        } else if confirmCount(of: segments, decodedEnd: decodedEndSeconds) > 0 {
            let held = confirmCount(of: segments, decodedEnd: decodedEndSeconds)
            // Whisper timestamps sometimes regress: anything ending at or before the watermark was already delivered, and the purge math needs the watermark to only move forward.
            let confirmable = segments.prefix(held)
                .filter { $0.end > lastConfirmedEndSeconds }
            if let furthestEnd = confirmable.map(\.end).max() {
                // Whisper pads the window to 30 s, so an end past the audio actually decoded is a hallucinated timestamp: taking it would start the next decode beyond speech nobody has read yet.
                lastConfirmedEndSeconds = max(lastConfirmedEndSeconds, min(furthestEnd, decodedEndSeconds))
                confirm(makeBatch(confirmable))
            }
            unconfirmedSegments = Array(segments.dropFirst(held))
        } else {
            unconfirmedSegments = segments
        }
        emitPartial()
        purgeConfirmedAudio()
        return false
    }

    private func confirm(_ batch: ConfirmedAudioBatch) {
        if let text = batch.segments.last?.text.trimmingCharacters(in: .whitespaces) {
            lastConfirmedWord = text.split(separator: " ").last.map(Self.comparable)
            lastConfirmedEndedSentence = text.last.map { ".?!…".contains($0) } ?? false
        }
        onConfirmed(batch)
    }

    private static func comparable(_ word: Substring) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    /// Only after a hard cut: no sentence end and no pause between the confirmed text and the new one.
    private func dropWordRepeatedAtCut(from segments: inout [TranscriptionSegment], decodeStart: Double) {
        guard let repeated = lastConfirmedWord, !lastConfirmedEndedSentence, var first = segments.first,
              Double(first.start) - decodeStart < 0.16, Double(first.start) - Double(lastConfirmedEndSeconds) < 0.25,
              let head = first.text.split(separator: " ", maxSplits: 1).first, Self.comparable(head) == repeated else { return }
        let rest = first.text.drop { !$0.isWhitespace }.drop { $0.isWhitespace }
        guard !rest.isEmpty else {
            segments.removeFirst()
            return
        }
        first.text = String(rest)
        if let words = first.words, words.count > 1 {
            first.words = Array(words.dropFirst())
            first.start = first.words?.first?.start ?? first.start
        }
        segments[0] = first
    }

    private func confirmCount(of segments: [TranscriptionSegment], decodedEnd: Float) -> Int {
        let held = max(0, segments.count - config.requiredSegmentsForConfirmation)
        guard let age = config.forceConfirmAfterSeconds else { return held }
        let cutoff = decodedEnd - Float(age)
        return max(held, segments.prefix { $0.end < cutoff }.count)
    }

    private func decodeFloorSeconds(decodedEnd: Double) -> Double {
        var floor = retainedFloorSeconds
        if let backoff = config.heldSegmentBackoffSeconds, let held = unconfirmedSegments.map({ Double($0.start) }).min() {
            floor = max(Double(lastConfirmedEndSeconds), held - backoff)
        }
        guard let maxDecode = config.maxDecodeSeconds else { return floor }
        return max(floor, decodedEnd - maxDecode)
    }

    /// Held-back segments the next decode could no longer reach: too old to wait for a successor, or before the part of the window it decodes.
    private func confirmStaleSegments(decodedEnd: Double) {
        guard let age = config.forceConfirmAfterSeconds, !unconfirmedSegments.isEmpty else { return }
        let reach = decodedEnd - (config.maxDecodeSeconds ?? .infinity)
        let (stale, kept) = unconfirmedSegments.reduce(into: ([TranscriptionSegment](), [TranscriptionSegment]())) { split, segment in
            if Double(segment.end) < decodedEnd - age || Double(segment.start) < reach {
                split.0.append(segment)
            } else {
                split.1.append(segment)
            }
        }
        guard !stale.isEmpty else { return }
        if let furthest = stale.map(\.end).max() {
            lastConfirmedEndSeconds = max(lastConfirmedEndSeconds, min(furthest, Float(decodedEnd)))
        }
        unconfirmedSegments = kept
        confirm(makeBatch(stale))
    }

    private func makeBatch(_ segments: [TranscriptionSegment]) -> ConfirmedAudioBatch {
        guard config.wantsConfirmedAudio,
              let earliestStart = segments.map(\.start).min(),
              let furthestEnd = segments.map(\.end).max() else {
            return ConfirmedAudioBatch(segments: segments, audioWindow: [], windowStartSeconds: 0)
        }
        let sampleRate = Double(config.sampleRate)
        let windowStart = Double(windowStartSample) / sampleRate
        let windowEnd = windowStart + Double(window.count) / sampleRate
        let sliceStart = max(windowStart, Double(earliestStart) - 0.5)
        let sliceEnd = min(windowEnd, Double(furthestEnd) + 0.5)
        let lowerBound = Int((sliceStart - windowStart) * sampleRate)
        let upperBound = min(window.count, Int((sliceEnd - windowStart) * sampleRate))
        guard lowerBound >= 0, lowerBound < upperBound else {
            return ConfirmedAudioBatch(segments: segments, audioWindow: [], windowStartSeconds: 0)
        }
        return ConfirmedAudioBatch(
            segments: segments,
            audioWindow: Array(window[lowerBound..<upperBound]),
            windowStartSeconds: sliceStart
        )
    }

    private func purgeConfirmedAudio() {
        let cutSeconds = retainedFloorSeconds - config.purgePadSeconds
        let cutSample = Int(cutSeconds * Double(config.sampleRate))
        let drop = min(max(0, cutSample - windowStartSample), window.count)
        guard drop > 0 else { return }
        window.removeFirst(drop)
        windowStartSample += drop
    }

    private func markWaitingForSpeech() {
        if currentText.isEmpty { currentText = Self.waitingForSpeech }
        emitPartial()
    }

    private func emitPartial() {
        let text: String
        if !unconfirmedSegments.isEmpty {
            text = unconfirmedSegments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        } else {
            text = currentText.trimmingCharacters(in: .whitespaces)
        }
        onPartial(text)
    }

    private static func shouldStopEarly(
        progress: TranscriptionProgress,
        options: DecodingOptions,
        compressionCheckWindow: Int
    ) -> Bool? {
        let currentTokens = progress.tokens
        if currentTokens.count > compressionCheckWindow {
            let checkTokens: [Int] = currentTokens.suffix(compressionCheckWindow)
            let compressionRatio = TextUtilities.compressionRatio(of: checkTokens)
            if compressionRatio > options.compressionRatioThreshold ?? 0.0 {
                return false
            }
        }
        if let avgLogprob = progress.avgLogprob, let logProbThreshold = options.logProbThreshold {
            if avgLogprob < logProbThreshold {
                return false
            }
        }
        return nil
    }
}
