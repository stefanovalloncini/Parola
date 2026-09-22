import Foundation
import os
@preconcurrency import FluidAudio

/// Parakeet TDT engine wrapper. Loads a CoreML Parakeet model on Apple Silicon via FluidAudio
/// and runs ASR on the Apple Neural Engine.
actor ParakeetTranscriber: Transcriber {
    static let engineID = EngineID.parakeet
    static let capabilities = EngineCapabilities.parakeetDefaults

    private let modelStore: ModelStore
    private var loadedModel: String?
    private var manager: AsrManager?
    private let signposter = OSSignposter(subsystem: "app.parola.core", category: "engine.parakeet")

    init(modelStore: ModelStore) {
        self.modelStore = modelStore
    }

    nonisolated static func supportedLanguages(forModel model: String) -> SupportedLanguages {
        ModelCatalog.staticCapabilities(forID: model)?.supportedLanguages ?? .only(["en"])
    }

    nonisolated static func accepts(language: String?, forModel model: String) -> Bool {
        guard let language else { return true }
        return supportedLanguages(forModel: model).allows(language)
    }

    /// The language a finished run is stamped with, and what the run can tell the user about it —
    /// nothing when they named it or the model speaks only English, which was never choosing. A
    /// guess is clamped to what the model speaks: an unsupported one is rejected by this very
    /// engine the next time the entry is run.
    nonisolated static func resolvedLanguage(
        for segments: [TranscriptSegment],
        options: TranscriptionOptions,
        model: String
    ) -> (language: String, detection: LanguageDetection?) {
        if let pinned = options.language?.lowercased() { return (pinned, nil) }
        let supported = supportedLanguages(forModel: model)
        guard !supported.isEnglishOnly else { return ("en", nil) }
        guard let guess = TextLanguageGuess.dominantLanguage(of: segments), supported.allows(guess) else {
            return ("en", .assumed("en"))
        }
        return (guess, .detected(guess))
    }

    func load(model: String) async throws {
        if loadedModel == model, manager != nil { return }
        let interval = signposter.beginInterval("load", "model=\(model, privacy: .public)")
        defer { signposter.endInterval("load", interval) }

        let version = try Self.modelVersion(for: model)
        let targetDir = modelStore.installedURL(for: model)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        do {
            let models = try await AsrModels.downloadAndLoad(to: targetDir, version: version)
            let asr = AsrManager(config: .default)
            try await asr.loadModels(models)
            self.manager = asr
            self.loadedModel = model
        } catch {
            ParolaLog.error(
                .engineParakeet, "model \(ModelToken(model)) failed to load",
                [.error: .error(error)]
            )
            throw ParolaError.transcriptionFailed("Parakeet load failed: \(error.localizedDescription)")
        }
    }

    func transcribe(
        url: URL,
        options: TranscriptionOptions,
        handlers: TranscribeHandlers
    ) async throws -> Transcript {
        guard let asr = manager, let modelName = loadedModel else {
            ParolaLog.fault(.engineParakeet, "transcribe called with no model loaded")
            throw ParolaError.transcriptionFailed("Parakeet model not loaded")
        }
        if let lang = options.language, !Self.accepts(language: lang, forModel: modelName) {
            ParolaLog.notice(.engineParakeet, "rejected language \(LanguageToken(lang))")
            let label = ModelCatalog.variant(id: modelName)?.displayName ?? modelName
            throw ParolaError.unsupportedForEngine("\(label) does not support \"\(lang)\"")
        }
        if options.task == .translate {
            ParolaLog.notice(.engineParakeet, "rejected translate: unsupported")
            throw ParolaError.unsupportedForEngine("Parakeet does not support translation")
        }
        let interval = signposter.beginInterval("transcribe", "model=\(modelName, privacy: .public)")
        defer { signposter.endInterval("transcribe", interval) }

        handlers.onStage?(.preparingAudio)
        var decoderState = TdtDecoderState.make()
        // FluidAudio decodes and infers inside one opaque call, so the run counts as transcribing from here.
        handlers.onStage?(.transcribing)
        let result: ASRResult
        let startedAt = ContinuousClock.now
        do {
            result = try await asr.transcribe(url, decoderState: &decoderState, language: nil)
        } catch {
            var fields: [LogField: LogValue] = [
                .model: .safe(ModelToken(modelName)),
                .elapsed: .duration(startedAt.duration(to: .now)),
                .error: .error(error),
            ]
            if let seconds = FileAudioSource(url: url).synchronousDuration() {
                fields[.audioSeconds] = .seconds(seconds)
            }
            ParolaLog.error(.engineParakeet, "transcribe failed", fields)
            throw ParolaError.transcriptionFailed("Parakeet transcribe failed: \(error.localizedDescription)")
        }

        let segments = Self.makeSegments(from: result, includeWords: options.wordTimestamps)
        let resolved = Self.resolvedLanguage(for: segments, options: options, model: modelName)
        // durationSeconds comes from the source asset, not the engine: TranscriptionSession fills it in.
        return Transcript(
            segments: segments,
            language: resolved.language,
            modelName: modelName,
            sourceURL: url,
            languageDetection: resolved.detection
        )
    }

    func unload() async {
        let interval = signposter.beginInterval("unload")
        defer { signposter.endInterval("unload", interval) }
        manager = nil
        loadedModel = nil
    }

    func loadedModelName() async -> String? { loadedModel }

    static func modelVersion(for model: String) throws -> AsrModelVersion {
        switch model {
        case "nvidia_parakeet-tdt-0.6b-v2":
            return .v2
        case "nvidia_parakeet-tdt-0.6b-v3":
            return .v3
        default:
            throw ParolaError.modelNotFound(model)
        }
    }

    /// Downloads only the files FluidAudio needs for a Parakeet variant.
    /// Avoids pulling sibling quantizations / older revisions stored in the same HF repo.
    static func download(
        model: String,
        to targetDir: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        let version = try modelVersion(for: model)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let aggregate = FileProgressAggregator(fileCount: ModelNames.ASR.requiredModels.count)
        do {
            return try await AsrModels.download(
                to: targetDir,
                version: version,
                progressHandler: { snapshot in
                    progress?(aggregate.overall(snapshot.fractionCompleted))
                }
            )
        } catch {
            if isCancellation(error) { throw CancellationError() }
            ParolaLog.error(
                .models, "parakeet download failed for \(ModelToken(model))",
                [.error: .error(error)]
            )
            throw ParolaError.modelDownloadFailed(model, underlying: String(describing: error))
        }
    }

    /// FluidAudio downloads one file per model spec and restarts its fraction at 0 for each one, so
    /// forwarding it raw drives the bar to 100% while three files are still to come. Give each file
    /// its own slice of the range and never let the total go backwards.
    final class FileProgressAggregator: Sendable {
        private let fileCount: Int
        private let state = OSAllocatedUnfairLock(initialState: (finished: 0, previous: 0.0, highest: 0.0))

        init(fileCount: Int) {
            self.fileCount = max(fileCount, 1)
        }

        func overall(_ fraction: Double) -> Double {
            let current = min(max(fraction, 0), 1)
            return state.withLock { state in
                if current < state.previous { state.finished = min(state.finished + 1, fileCount - 1) }
                state.previous = current
                let total = (Double(state.finished) + current) / Double(fileCount)
                state.highest = max(state.highest, total)
                return state.highest
            }
        }
    }

    static let segmentGapThreshold: TimeInterval = 0.8
    static let maxTokensPerSegment: Int = 80

    /// Group token timings into segments. Splits on silence gaps over `segmentGapThreshold`
    /// seconds or when a run reaches `maxTokensPerSegment`. Falls back to a single segment
    /// containing the full text.
    static func makeSegments(from result: ASRResult, includeWords: Bool) -> [TranscriptSegment] {
        let trimmedText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            guard !trimmedText.isEmpty else { return [] }
            return [TranscriptSegment(id: 0, start: 0, end: result.duration, text: trimmedText, words: nil)]
        }

        var segments: [TranscriptSegment] = []
        var currentTokens: [TokenTiming] = []
        var lastEnd: TimeInterval = 0
        var nextID = 0

        func flush() {
            guard let first = currentTokens.first, let last = currentTokens.last else { return }
            let text = currentTokens
                .map(\.token)
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                currentTokens.removeAll()
                return
            }
            let words: [WordTiming]? = includeWords
                ? mergeWords(
                    currentTokens.map {
                        WordPiece(token: $0.token, start: $0.startTime, end: $0.endTime, confidence: Double($0.confidence))
                    },
                    segmentID: nextID
                )
                : nil
            segments.append(TranscriptSegment(
                id: nextID,
                start: first.startTime,
                end: last.endTime,
                text: text,
                words: words
            ))
            nextID += 1
            currentTokens.removeAll()
        }

        for timing in timings {
            if !currentTokens.isEmpty {
                let gap = timing.startTime - lastEnd
                if gap > segmentGapThreshold || currentTokens.count >= maxTokensPerSegment {
                    flush()
                }
            }
            currentTokens.append(timing)
            lastEnd = timing.endTime
        }
        flush()

        if segments.isEmpty, !trimmedText.isEmpty {
            return [TranscriptSegment(id: 0, start: 0, end: result.duration, text: trimmedText, words: nil)]
        }
        return segments
    }

    struct WordPiece: Sendable {
        let token: String
        let start: Double
        let end: Double
        let confidence: Double
    }

    /// Merges SentencePiece sub-word tokens into whole words. FluidAudio marks a word start with a
    /// leading space (the normalized `▁`); continuation pieces have none. Emitting one WordTiming per
    /// raw token splits words ("transcri" + "ption"), breaking karaoke highlight and word diarization.
    static func mergeWords(_ pieces: [WordPiece], segmentID: Int) -> [WordTiming] {
        var words: [WordTiming] = []
        var group: [WordPiece] = []

        func emit() {
            defer { group.removeAll() }
            guard let first = group.first, let last = group.last else { return }
            let text = group.map(\.token).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let confidence = group.reduce(0.0) { $0 + $1.confidence } / Double(group.count)
            words.append(WordTiming(
                id: "\(segmentID)-\(words.count)",
                word: text,
                start: first.start,
                end: last.end,
                probability: confidence
            ))
        }

        for piece in pieces {
            let startsWord = piece.token.first.map { $0 == " " || $0 == "\n" || $0 == "\t" } ?? false
            if startsWord, !group.isEmpty { emit() }
            group.append(piece)
        }
        emit()
        return words
    }
}
