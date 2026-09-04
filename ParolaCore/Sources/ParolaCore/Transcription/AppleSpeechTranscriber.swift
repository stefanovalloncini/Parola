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

    private let modelStore: ModelStore
    private var loadedModel: String?
    private var inFlightCancel: (@Sendable () async -> Void)?
    private var inFlightEpoch: Int = 0
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
            throw ParolaError.transcriptionFailed("Apple Speech engine not loaded")
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
        let priorCancel = inFlightCancel
        inFlightEpoch &+= 1
        let myEpoch = inFlightEpoch
        inFlightCancel = { [weak cancellation] in await cancellation?.cancel() }
        if let priorCancel {
            await priorCancel()
        }
        defer {
            if inFlightEpoch == myEpoch {
                inFlightCancel = nil
            }
        }
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

    func cancelInFlight() async {
        await inFlightCancel?()
    }

    func unload() async {
        let interval = signposter.beginInterval("unload")
        defer { signposter.endInterval("unload", interval) }
        await cancelInFlight()
        loadedModel = nil
    }

    func loadedModelName() async -> String? { loadedModel }

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

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        await cancellation.attach(analyzer: analyzer)
        let audioFile = try AVAudioFile(forReading: url)
        let durationSeconds = Double(audioFile.length) / audioFile.processingFormat.sampleRate

        let collectorTask = Task { () async throws -> (segments: [TranscriptSegment], confidence: Double?) in
            var segments: [TranscriptSegment] = []
            var meter = ConfidenceMeter()
            var nextID = 0
            var assembler = SpeechPartialAssembler()
            var sawFirstResult = false
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
                handlers.onProgress?(end)
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
                handlers.onPartial?(assembler.tail())
            }
            return (segments, meter.value)
        }

        let run: (segments: [TranscriptSegment], confidence: Double?)
        let startedAt = ContinuousClock.now
        do {
            run = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                _ = try await analyzer.analyzeSequence(from: audioFile)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                return try await collectorTask.value
            } onCancel: {
                collectorTask.cancel()
                Task { await cancellation.cancel() }
            }
        } catch is CancellationError {
            collectorTask.cancel()
            throw CancellationError()
        } catch {
            collectorTask.cancel()
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

        let resolvedLanguage = locale.language.languageCode?.identifier
            ?? options.language
            ?? "en"
        return Transcript(
            segments: run.segments,
            language: resolvedLanguage,
            modelName: modelName,
            sourceURL: url,
            durationSeconds: durationSeconds > 0 ? durationSeconds : nil,
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

        let probeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-language-probe-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: probeURL) }
        guard let windows = try? ProbeAudioExtractor.extract(from: url, to: probeURL),
              !windows.isEmpty else { return nil }

        let picker = AutoLanguagePicker { locale in
            try await Self.runProbe(url: probeURL, locale: locale, cancellation: cancellation)
        }
        return try await picker.pick(candidates: candidates, fallback: fallback)
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
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        await cancellation.attach(analyzer: analyzer)
        let file = try AVAudioFile(forReading: url)
        let collector = Task { () async throws -> LanguageProbeOutcome in
            var parts: [String] = []
            var meter = ConfidenceMeter()
            for try await result in transcriber.results where result.isFinal {
                parts.append(String(result.text.characters))
                meter.add(result.text)
            }
            return LanguageProbeOutcome(text: parts.joined(separator: " "), confidence: meter.value)
        }
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                _ = try await analyzer.analyzeSequence(from: file)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                return try await collector.value
            } onCancel: {
                collector.cancel()
                Task { await cancellation.cancel() }
            }
        } catch {
            collector.cancel()
            throw error
        }
    }
    #endif

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

#if canImport(Speech)
@available(macOS 26.0, iOS 26.0, *)
private struct ConfidenceMeter {
    private var weighted = 0.0
    private var weight = 0.0

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

@available(macOS 26.0, iOS 26.0, *)
final actor AnalyzerCancellation {
    private var analyzer: SpeechAnalyzer?
    private var cancelled = false

    func attach(analyzer: SpeechAnalyzer) async {
        if cancelled {
            await analyzer.cancelAndFinishNow()
            return
        }
        self.analyzer = analyzer
    }

    func cancel() async {
        cancelled = true
        guard let analyzer else { return }
        self.analyzer = nil
        await analyzer.cancelAndFinishNow()
    }
}
#else
final actor AnalyzerCancellation {
    func cancel() async {}
}
#endif
