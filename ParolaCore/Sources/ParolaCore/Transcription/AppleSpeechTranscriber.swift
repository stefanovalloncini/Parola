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

    func transcribe(url: URL, options: TranscriptionOptions) async throws -> Transcript {
        try await transcribe(url: url, options: options, partialHandler: nil, progressHandler: nil)
    }

    func transcribe(
        url: URL,
        options: TranscriptionOptions,
        partialHandler: (@Sendable (String) -> Void)?,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> Transcript {
        guard let modelName = loadedModel else {
            throw ParolaError.transcriptionFailed("Apple Speech engine not loaded")
        }
        if options.task == .translate {
            throw ParolaError.unsupportedForEngine("Apple Speech does not support translation")
        }
        guard #available(macOS 26.0, iOS 26.0, *) else {
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
            partialHandler: partialHandler,
            progressHandler: progressHandler
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
        partialHandler: (@Sendable (String) -> Void)?,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> Transcript {
        #if canImport(Speech)
        let locale = Self.pickLocale(language: options.language)

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ParolaError.unsupportedForEngine(
                "Apple Speech has no model for \(locale.identifier): \(error.localizedDescription)"
            )
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        await cancellation.attach(analyzer: analyzer)
        let audioFile = try AVAudioFile(forReading: url)
        let durationSeconds = Double(audioFile.length) / audioFile.processingFormat.sampleRate

        let collectorTask = Task { () async throws -> [TranscriptSegment] in
            var segments: [TranscriptSegment] = []
            var nextID = 0
            var assembler = SpeechPartialAssembler()
            for try await result in transcriber.results {
                guard result.isFinal else { continue }
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = result.range.start.seconds
                let end = result.range.end.seconds
                progressHandler?(end)
                segments.append(TranscriptSegment(
                    id: nextID,
                    start: start,
                    end: end,
                    text: text,
                    words: nil
                ))
                nextID += 1
                assembler.addFinal(text)
                partialHandler?(assembler.text)
            }
            return segments
        }

        let segments: [TranscriptSegment]
        do {
            segments = try await withTaskCancellationHandler {
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
            throw ParolaError.transcriptionFailed("Apple Speech failed: \(error.localizedDescription)")
        }

        let resolvedLanguage = locale.language.languageCode?.identifier
            ?? options.language
            ?? "en"
        return Transcript(
            segments: segments,
            language: resolvedLanguage,
            modelName: modelName,
            sourceURL: url,
            durationSeconds: durationSeconds > 0 ? durationSeconds : nil
        )
        #else
        throw ParolaError.unsupportedForEngine("Apple Speech framework not available in this build.")
        #endif
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

#if canImport(Speech)
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
