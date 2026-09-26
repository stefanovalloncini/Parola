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
    }

    struct Dependencies: Sendable {
        var requestPermission: @Sendable () async -> Bool
        var startCapture: @Sendable (@escaping @Sendable ([Float]) -> Void) throws -> Void
        var stopCapture: @Sendable () -> Void
        var transcribe: @Sendable ([Float], DecodingOptions, @escaping TranscriptionCallback) async throws -> TranscriptionResult
        var tick: @Sendable () async throws -> Void
    }

    enum Outcome: Sendable {
        case stopped
        case cancelled
        case permissionDenied
        case failed(any Error)
    }

    private struct Inbox: Sendable {
        var pending: [Float] = []
        var energies: [(rel: Float, avg: Float)] = []
    }

    // Trimming old entries is safe: VAD only reads a recent suffix (baseline over the last 20, voice check over the new-audio span).
    private static let maxEnergyEntries = 4096
    private static let waitingForSpeech = "Waiting for speech..."

    private let config: Configuration
    private let baseDecodingOptions: DecodingOptions
    private let deps: Dependencies
    private let onPartial: @Sendable (String) -> Void
    private let onEnergy: @Sendable (Float) -> Void
    private let onConfirmed: @Sendable (ConfirmedAudioBatch) -> Void
    private let inbox = OSAllocatedUnfairLock(initialState: Inbox())

    private var window: [Float] = []
    private var windowStartSample = 0
    private var lastTranscribedTotal = 0
    private var lastConfirmedEndSeconds: Float = 0
    private var unconfirmedSegments: [TranscriptionSegment] = []
    private var currentText = ""
    private var isRunning = false
    private var didStopCapture = false
    private var stopRequested = false

    init(
        configuration: Configuration,
        decodingOptions: DecodingOptions,
        dependencies: Dependencies,
        onPartial: @escaping @Sendable (String) -> Void,
        onEnergy: @escaping @Sendable (Float) -> Void,
        onConfirmed: @escaping @Sendable (ConfirmedAudioBatch) -> Void
    ) {
        self.config = configuration
        self.baseDecodingOptions = decodingOptions
        self.deps = dependencies
        self.onPartial = onPartial
        self.onEnergy = onEnergy
        self.onConfirmed = onConfirmed
    }

    func run() async -> Outcome {
        guard await deps.requestPermission() else {
            ParolaLog.notice(.streaming, "microphone permission denied")
            return .permissionDenied
        }
        // stop() can land while the first-run prompt is up; Allow must not bring up a mic nobody can stop.
        guard !stopRequested else { return .stopped }
        let startedAt = ContinuousClock.now
        do {
            try deps.startCapture { [weak self] buffer in self?.ingest(buffer) }
        } catch {
            ParolaLog.error(.streaming, "streaming capture failed to start", [.error: .error(error)])
            stopCapture()
            return .failed(error)
        }
        isRunning = true
        while isRunning {
            do {
                try await iterate()
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
                return .failed(error)
            }
        }
        // Runs on this task, never from stop(): a flush entering the actor mid-iterate
        // would race the in-flight decode on the shared TranscribeTask.
        await finalFlush()
        return .stopped
    }

    /// Decodes audio that arrived after the last iteration — the 1-second cadence gate
    /// would otherwise drop the user's final word at stop — and promotes whatever ends
    /// up unconfirmed: with no further audio coming, the last hypothesis is final.
    private func finalFlush() async {
        drainInbox()
        enforceWindowCap()
        let totalSamples = windowStartSample + window.count
        let newSeconds = Float(totalSamples - lastTranscribedTotal) / Float(config.sampleRate)
        if newSeconds > 0.05, voiceDetectedInTail(newSeconds) {
            lastTranscribedTotal = totalSamples
            try? await transcribeWindow(confirmAll: true)
        }
        guard !unconfirmedSegments.isEmpty else { return }
        if let last = unconfirmedSegments.last, last.end > lastConfirmedEndSeconds {
            lastConfirmedEndSeconds = last.end
        }
        onConfirmed(makeBatch(unconfirmedSegments))
        unconfirmedSegments = []
    }

    // Mirrors iterate()'s gate so a silent tail (VAD held it back all along) isn't
    // suddenly decoded at stop — Whisper hallucinates on long silence.
    private func voiceDetectedInTail(_ newSeconds: Float) -> Bool {
        guard config.useVAD else { return true }
        return voiceDetected(inNext: newSeconds)
    }

    private func voiceDetected(inNext seconds: Float) -> Bool {
        // isVoiceDetected only reads one entry per 100 ms of new audio off the end, so a longer snapshot would just hold the capture callback's lock for longer.
        let considered = max(0, Int(seconds / 0.1))
        let energies = inbox.withLock { $0.energies.suffix(considered).map(\.rel) }
        return AudioProcessor.isVoiceDetected(
            in: energies,
            nextBufferInSeconds: seconds,
            silenceThreshold: config.silenceThreshold
        )
    }

    func stop() {
        stopRequested = true
        isRunning = false
        stopCapture()
    }

    private func stopCapture() {
        guard !didStopCapture else { return }
        didStopCapture = true
        deps.stopCapture()
    }

    func windowSampleCount() -> Int { window.count }

    func windowStartOffsetSamples() -> Int { windowStartSample }

    nonisolated private func ingest(_ buffer: [Float]) {
        guard !buffer.isEmpty else { return }
        let avgEnergy = AudioProcessor.calculateEnergy(of: buffer).avg
        let rel = inbox.withLock { box -> Float in
            let baseline = box.energies.suffix(20).map(\.avg).min() ?? .infinity
            let rel = AudioProcessor.calculateRelativeEnergy(of: buffer, relativeTo: baseline)
            box.pending.append(contentsOf: buffer)
            box.energies.append((rel: rel, avg: avgEnergy))
            if box.energies.count > Self.maxEnergyEntries {
                box.energies.removeFirst(box.energies.count - Self.maxEnergyEntries)
            }
            return rel
        }
        onEnergy(rel)
    }

    private func iterate() async throws {
        drainInbox()
        enforceWindowCap()
        let totalSamples = windowStartSample + window.count
        let newSeconds = Float(totalSamples - lastTranscribedTotal) / Float(config.sampleRate)
        guard newSeconds > 1 else {
            markWaitingForSpeech()
            return try await deps.tick()
        }
        if config.useVAD, !voiceDetected(inNext: newSeconds) {
            markWaitingForSpeech()
            return try await deps.tick()
        }
        lastTranscribedTotal = totalSamples
        try await transcribeWindow()
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

    private func transcribeWindow(confirmAll: Bool = false) async throws {
        let offsetSeconds = Double(windowStartSample) / Double(config.sampleRate)
        let decodedEndSeconds = Float(offsetSeconds + Double(window.count) / Double(config.sampleRate))
        var options = baseDecodingOptions
        // clipTimestamps is window-relative; everything emitted from here back out must be absolute.
        options.clipTimestamps = [Float(max(0, retainedFloorSeconds - offsetSeconds))]
        let emitProgressPartials = unconfirmedSegments.isEmpty
        let onPartial = self.onPartial
        let compressionCheckWindow = config.compressionCheckWindow
        let result = try await deps.transcribe(window, options) { [options] progress in
            if emitProgressPartials {
                onPartial(progress.text.trimmingCharacters(in: .whitespaces))
            }
            return Self.shouldStopEarly(
                progress: progress,
                options: options,
                compressionCheckWindow: compressionCheckWindow
            )
        }
        currentText = ""
        let offset = Float(offsetSeconds)
        let segments = result.segments.map { segment -> TranscriptionSegment in
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
        if confirmAll {
            if let last = segments.last, last.end > lastConfirmedEndSeconds {
                lastConfirmedEndSeconds = last.end
            }
            if !segments.isEmpty {
                onConfirmed(makeBatch(segments))
            }
            unconfirmedSegments = []
        } else if segments.count > config.requiredSegmentsForConfirmation {
            // Whisper timestamps sometimes regress: anything ending at or before the watermark was already delivered, and the purge math needs the watermark to only move forward.
            let confirmable = segments.prefix(segments.count - config.requiredSegmentsForConfirmation)
                .filter { $0.end > lastConfirmedEndSeconds }
            if let furthestEnd = confirmable.map(\.end).max() {
                // Whisper pads the window to 30 s, so an end past the audio actually decoded is a hallucinated timestamp: taking it would start the next decode beyond speech nobody has read yet.
                lastConfirmedEndSeconds = max(lastConfirmedEndSeconds, min(furthestEnd, decodedEndSeconds))
                onConfirmed(makeBatch(confirmable))
            }
            unconfirmedSegments = Array(segments.suffix(config.requiredSegmentsForConfirmation))
        } else {
            unconfirmedSegments = segments
        }
        emitPartial()
        purgeConfirmedAudio()
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
