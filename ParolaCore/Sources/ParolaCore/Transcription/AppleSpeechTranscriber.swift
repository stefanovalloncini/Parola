import Foundation
import AVFoundation
import CoreMedia
import os

#if canImport(Speech)
import Speech
#endif

actor AppleSpeechTranscriber: Transcriber {
    static let engineID = EngineID.appleSpeech
    static let capabilities = EngineCapabilities.appleSpeechDefaults

    static let syntheticModelID = "apple-speech-analyzer"

    static let callbackInterval: Duration = .milliseconds(100)

    private let modelStore: ModelStore
    private var loadedModel: String?
    private let inFlight = InFlightCancel()
    private let signposter = OSSignposter(subsystem: "app.parola.core", category: "engine.apple-speech")

    init(modelStore: ModelStore) {
        self.modelStore = modelStore
    }

    func load(model: String) async throws {
        let interval = signposter.beginInterval("load", "model=\(model, privacy: .public)")
        defer { signposter.endInterval("load", interval) }
        loadedModel = model
    }

    func transcribe(
        url: URL,
        options: TranscriptionOptions,
        handlers: TranscribeHandlers
    ) async throws -> Transcript {
        guard let modelName = loadedModel else {
            throw ParolaError.engineLoadFailed("Apple Speech engine not loaded")
        }
        if options.task == .translate {
            throw ParolaError.unsupportedForEngine("Apple Speech does not support translation")
        }
        guard #available(macOS 26.0, iOS 26.0, *) else {
            ParolaLog.notice(.engineAppleSpeech, "engine unavailable on this OS")
            throw ParolaError.unsupportedForEngine(
                "Apple SpeechAnalyzer requires macOS 26 or iOS 26."
            )
        }
        #if canImport(Speech)
        let interval = signposter.beginInterval("transcribe", "model=\(modelName, privacy: .public)")
        defer { signposter.endInterval("transcribe", interval) }
        let cancellation = AnalyzerCancellation()
        let claim = inFlight.claim { [weak cancellation] in await cancellation?.cancel() }
        if let prior = claim.prior {
            await prior()
        }
        defer { inFlight.release(claim.epoch) }
        return try await runSpeechAnalyzer(
            url: url,
            options: options,
            modelName: modelName,
            cancellation: cancellation,
            handlers: handlers
        )
        #else
        throw ParolaError.unsupportedForEngine("Apple Speech framework not available in this build.")
        #endif
    }

    /// Off the actor: the session's stall-abandon has to reach a run whatever the actor is doing.
    nonisolated func cancelInFlight() async {
        await inFlight.cancel()
    }

    func unload() async {
        let interval = signposter.beginInterval("unload")
        defer { signposter.endInterval("unload", interval) }
        await cancelInFlight()
        loadedModel = nil
    }

    func loadedModelName() async -> String? { loadedModel }

    @available(macOS 26.0, iOS 26.0, *)
    private static func tearDown(
        _ collector: Task<(segments: [TranscriptSegment], confidence: Double?), any Error>,
        cancellation: AnalyzerCancellation
    ) async {
        collector.cancel()
        await cancellation.cancel()
        _ = await collector.result
    }

    @available(macOS 26.0, iOS 26.0, *)
    private func runSpeechAnalyzer(
        url: URL,
        options: TranscriptionOptions,
        modelName: String,
        cancellation: AnalyzerCancellation,
        handlers: TranscribeHandlers
    ) async throws -> Transcript {
        #if canImport(Speech)
        handlers.onStage?(.preparingAudio)
        let resolution = try await resolveLocale(
            url: url,
            language: options.language,
            cancellation: cancellation
        )
        let locale = resolution.locale

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: resolution.needsRunConfidence
                ? [.audioTimeRange, .transcriptionConfidence]
                : [.audioTimeRange]
        )

        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            ParolaLog.error(.engineAppleSpeech, "analyzer setup failed", [.error: .error(error)])
            throw ParolaError.unsupportedForEngine(
                "Apple Speech has no model for \(locale.identifier): \(error.localizedDescription)"
            )
        }

        await SettleGate.shared.waitUntilSettled()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        await cancellation.attach(analyzer: analyzer)
        let audioFile = try await Self.openBounded(url)
        let durationSeconds = Double(audioFile.length) / audioFile.processingFormat.sampleRate

        let collectorTask = Task { () async throws -> (segments: [TranscriptSegment], confidence: Double?) in
            var segments: [TranscriptSegment] = []
            var meter = ConfidenceMeter()
            var nextID = 0
            var assembler = SpeechPartialAssembler()
            var sawFirstResult = false
            var progress = CallbackCoalescer<Double>(minimumInterval: Self.callbackInterval)
            var partials = CallbackCoalescer<String>(minimumInterval: Self.callbackInterval)
            for try await result in transcriber.results {
                if !sawFirstResult {
                    sawFirstResult = true
                    handlers.onStage?(.transcribing)
                }
                guard result.isFinal else { continue }
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = result.range.start.seconds
                let end = result.range.end.seconds
                if let reported = progress.offer(end) { handlers.onProgress?(reported) }
                segments.append(TranscriptSegment(
                    id: nextID,
                    start: start,
                    end: end,
                    text: text,
                    words: nil
                ))
                nextID += 1
                meter.add(result.text)
                assembler.addFinal(text)
                if let tail = partials.offer(assembler.tail()) { handlers.onPartial?(tail) }
            }
            if !Task.isCancelled {
                if let reported = progress.flush() { handlers.onProgress?(reported) }
                if let tail = partials.flush() { handlers.onPartial?(tail) }
            }
            return (segments, meter.value)
        }

        let run: (analyzedThrough: Double?, segments: [TranscriptSegment], confidence: Double?)
        let startedAt = ContinuousClock.now
        do {
            run = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let lastAnalyzed = try await analyzer.analyzeSequence(from: audioFile)
                try await cancellation.throwIfCancelled()
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                let collected = try await collectorTask.value
                return (lastAnalyzed?.seconds, collected.segments, collected.confidence)
            } onCancel: {
                collectorTask.cancel()
                Task { await cancellation.cancel() }
            }
        } catch is CancellationError {
            await Self.tearDown(collectorTask, cancellation: cancellation)
            throw CancellationError()
        } catch {
            await Self.tearDown(collectorTask, cancellation: cancellation)
            ParolaLog.error(
                .engineAppleSpeech, "transcribe failed",
                [
                    .audioSeconds: .seconds(durationSeconds),
                    .elapsed: .duration(startedAt.duration(to: .now)),
                    .error: .error(error),
                ]
            )
            throw ParolaError.transcriptionFailed("Apple Speech failed: \(error.localizedDescription)")
        }

        Self.logUnreportedTail(
            duration: durationSeconds,
            analyzedThrough: run.analyzedThrough,
            lastResultEnd: run.segments.map(\.end).max()
        )
        let resolvedLanguage = locale.language.languageCode?.identifier
            ?? options.language
            ?? "en"
        // durationSeconds comes from the source asset, not the engine: TranscriptionSession fills it in.
        return Transcript(
            segments: run.segments,
            language: resolvedLanguage,
            modelName: modelName,
            sourceURL: url,
            languageDetection: resolution.detection(
                afterRun: run.confidence,
                isEmpty: run.segments.isEmpty
            )
        )
        #else
        throw ParolaError.unsupportedForEngine("Apple Speech framework not available in this build.")
        #endif
    }

    @available(macOS 26.0, iOS 26.0, *)
    private func resolveLocale(
        url: URL,
        language: String?,
        cancellation: AnalyzerCancellation
    ) async throws -> LocaleResolution {
        #if canImport(Speech)
        if let language, !language.isEmpty {
            return .specified(Self.pickLocale(language: language))
        }
        let fallback = Self.pickLocale(language: nil)
        guard let pick = try await detectLocale(url: url, fallback: fallback, cancellation: cancellation) else {
            return .unverified(fallback)
        }
        return .probed(pick)
        #else
        return .specified(Self.pickLocale(language: language))
        #endif
    }

    #if canImport(Speech)
    @available(macOS 26.0, iOS 26.0, *)
    private func detectLocale(
        url: URL,
        fallback: Locale,
        cancellation: AnalyzerCancellation
    ) async throws -> LanguagePick? {
        let interval = signposter.beginInterval("detect-language")
        defer { signposter.endInterval("detect-language", interval) }
        // Only languages whose Speech assets are already on disk are probed: installing one costs
        // a download the user never asked for, mid-transcribe.
        let candidates = LanguageCandidates.installedMatches(
            for: LanguageCandidates.autoDetect(preferred: Locale.preferredLanguages, current: fallback),
            installed: await SpeechTranscriber.installedLocales
        )
        guard candidates.count > 1 else { return nil }

        return try await LanguageProbeScratch.withScratch(from: url) { windows in
            let picker = AutoLanguagePicker(windowCount: windows.count) { locale, window in
                try await Self.runProbe(url: windows[window], locale: locale, cancellation: cancellation)
            }
            return try await picker.pick(candidates: candidates, fallback: fallback)
        }
    }

    @available(macOS 26.0, iOS 26.0, *)
    private static func runProbe(
        url: URL,
        locale: Locale,
        cancellation: AnalyzerCancellation
    ) async throws -> LanguageProbeOutcome {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.transcriptionConfidence]
        )
        await SettleGate.shared.waitUntilSettled()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        await cancellation.attach(analyzer: analyzer)
        let collector = Task { () async throws -> LanguageProbeOutcome in
            var parts: [String] = []
            var meter = ConfidenceMeter()
            for try await result in transcriber.results where result.isFinal {
                parts.append(String(result.text.characters))
                meter.add(result.text)
            }
            return LanguageProbeOutcome(
                text: parts.joined(separator: " "),
                confidence: meter.value,
                confidenceWeight: meter.weight
            )
        }
        do {
            let file = try await openBounded(url)
            let outcome = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                _ = try await analyzer.analyzeSequence(from: file)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                return try await collector.value
            } onCancel: {
                collector.cancel()
                // analyzeSequence ignores task cancellation and never returns without this.
                Task { await AnalyzerCancellation.stop(analyzer) }
            }
            await cancellation.detach(analyzer: analyzer)
            return outcome
        } catch {
            collector.cancel()
            await cancellation.detach(analyzer: analyzer)
            throw error
        }
    }
    #endif

    /// A file on a stalled share parks `open()` in a syscall nothing can interrupt.
    static func openBounded(_ url: URL, deadline: Duration = FileReadDeadline.header) async throws -> AVAudioFile {
        let read = await BoundedFileRead.run(deadline: deadline) {
            Result { OpenedAudioFile(file: try AVAudioFile(forReading: url)) }
        }
        guard case .done(let opened) = read else {
            throw ParolaError.fileReadTimedOut(name: url.lastPathComponent)
        }
        return try opened.get().file
    }

    /// Under a quarter-minute of trailing silence is ordinary; past that the transcript looks
    /// truncated to a reader and it is worth knowing whether the analyzer read that far.
    static let notableTailSeconds = 15.0

    static func unreportedTail(duration: Double, lastResultEnd: Double?) -> Double? {
        guard duration.isFinite, duration > 0 else { return nil }
        let tail = duration - max(0, lastResultEnd ?? 0)
        return tail >= notableTailSeconds ? tail : nil
    }

    /// Speech reads a file to the end and still returns nothing for a quiet tail, which is
    /// indistinguishable downstream from a run that stopped short. The two numbers separate them.
    private static func logUnreportedTail(
        duration: Double, analyzedThrough: Double?, lastResultEnd: Double?
    ) {
        guard let tail = unreportedTail(duration: duration, lastResultEnd: lastResultEnd) else { return }
        ParolaLog.notice(
            .engineAppleSpeech, "analyzer returned nothing for the tail",
            [
                .audioSeconds: .seconds(duration),
                .analyzed: .seconds(analyzedThrough ?? 0),
                .offset: .seconds(lastResultEnd ?? 0),
                .count: .int(Int(tail.rounded())),
            ]
        )
    }

    static let regionDefaults: [String: String] = [
        "en": "US", "it": "IT", "fr": "FR", "de": "DE", "es": "ES",
        "pt": "BR", "ja": "JP", "zh": "CN", "ko": "KR", "ru": "RU",
        "ar": "SA", "nl": "NL", "pl": "PL", "tr": "TR", "hi": "IN"
    ]

    static func pickLocale(language: String?) -> Locale {
        guard let language, !language.isEmpty else { return Locale.current }
        if language.contains("-") || language.contains("_") {
            return Locale(identifier: language)
        }
        // For a language without a known region default, use the bare-language locale rather than
        // fabricating "<lang>_US" — Speech has no "sv_US" model, but resolves "sv" to its best match.
        guard let region = regionDefaults[language.lowercased()] else {
            return Locale(identifier: language)
        }
        return Locale(identifier: "\(language)_\(region)")
    }
}

// The file crosses from the reading thread to the task awaiting it once and is never shared.
private struct OpenedAudioFile: @unchecked Sendable {
    let file: AVAudioFile
}

/// The running analyzer's cancel, behind a lock so it is reachable while the actor is busy.
final class InFlightCancel: Sendable {
    typealias Cancel = @Sendable () async -> Void

    private struct State {
        var cancel: Cancel?
        var epoch = 0
    }

    struct Claim {
        var epoch: Int
        var prior: Cancel?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Installs a new run's cancel and hands back the one a previous run left behind.
    func claim(_ cancel: @escaping Cancel) -> Claim {
        state.withLock { state in
            let prior = state.cancel
            state.epoch &+= 1
            state.cancel = cancel
            return Claim(epoch: state.epoch, prior: prior)
        }
    }

    /// Clears the cancel only if no later run has claimed the engine since.
    func release(_ epoch: Int) {
        state.withLock { state in
            if state.epoch == epoch { state.cancel = nil }
        }
    }

    func cancel() async {
        let cancel = state.withLock { $0.cancel }
        await cancel?()
    }
}

#if canImport(Speech)
@available(macOS 26.0, iOS 26.0, *)
private struct ConfidenceMeter {
    private var weighted = 0.0
    private(set) var weight = 0.0

    var value: Double? { weight > 0 ? weighted / weight : nil }

    mutating func add(_ text: AttributedString) {
        for run in text.runs {
            guard let confidence = run.transcriptionConfidence else { continue }
            let length = Double(text[run.range].characters.count)
            weighted += confidence * length
            weight += length
        }
    }
}

/// Keeps every new analyzer in the process from starting while a cancelled one is still being torn down.
final class SettleGate: Sendable {
    // Speech keeps tearing a cancelled analyzer down for ~10 ms after cancelAndFinishNow returns; one started sooner can transcribe differently (2 ms gap: 6 of 8 runs differed, 20 ms: 0 of 24).
    static let shared = SettleGate(duration: .milliseconds(100))

    private struct State {
        var stopping = 0
        var settledAt = ContinuousClock.now
    }

    private let duration: Duration
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(duration: Duration) {
        self.duration = duration
    }

    func beginStop() {
        state.withLock { $0.stopping += 1 }
    }

    func endStop() {
        state.withLock {
            $0.stopping -= 1
            $0.settledAt = ContinuousClock.now + duration
        }
    }

    /// Returns when no stop is running and the last one has settled, or after `limit` so a stop that never returns can't
    /// hold every later run; sleeps in a fresh task so a cancelled caller still waits.
    func waitUntilSettled(limit: Duration = .seconds(2)) async {
        await Task {
            let deadline = ContinuousClock.now + limit
            while true {
                let (stopping, settledAt) = state.withLock { ($0.stopping, $0.settledAt) }
                if stopping == 0, ContinuousClock.now >= settledAt { return }
                guard ContinuousClock.now < deadline else {
                    ParolaLog.notice(.engineAppleSpeech, "analyzer settle wait gave up")
                    return
                }
                let wait = stopping > 0 ? .milliseconds(5) : ContinuousClock.now.duration(to: settledAt)
                try? await Task.sleep(for: min(wait, ContinuousClock.now.duration(to: deadline)))
            }
        }.value
    }
}

@available(macOS 26.0, iOS 26.0, *)
final actor AnalyzerCancellation {
    private var analyzers: [ObjectIdentifier: SpeechAnalyzer] = [:]
    private var cancelled = false
    private var stopping: Task<Void, Never>?

    static func stop(_ analyzer: SpeechAnalyzer, gate: SettleGate = .shared) async {
        gate.beginStop()
        await analyzer.cancelAndFinishNow()
        gate.endStop()
        await gate.waitUntilSettled()
    }

    func attach(analyzer: SpeechAnalyzer) async {
        if cancelled {
            await Self.stop(analyzer)
            return
        }
        analyzers[ObjectIdentifier(analyzer)] = analyzer
    }

    func throwIfCancelled() throws {
        if cancelled || Task.isCancelled { throw CancellationError() }
    }

    func detach(analyzer: SpeechAnalyzer) {
        analyzers[ObjectIdentifier(analyzer)] = nil
    }

    /// Returns once every analyzer it stopped, now or in an earlier call, has settled.
    func cancel() async {
        cancelled = true
        let running = Array(analyzers.values)
        analyzers = [:]
        if !running.isEmpty {
            let earlier = stopping
            stopping = Task {
                await earlier?.value
                for analyzer in running { await Self.stop(analyzer) }
            }
        }
        await stopping?.value
    }
}
#else
final actor AnalyzerCancellation {
    func cancel() async {}
}
#endif
