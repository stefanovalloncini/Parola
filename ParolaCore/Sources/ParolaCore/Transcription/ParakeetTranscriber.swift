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
            throw ParolaError.transcriptionFailed("Parakeet load failed: \(error.localizedDescription)")
        }
    }

    func transcribe(url: URL, options: TranscriptionOptions) async throws -> Transcript {
        guard let asr = manager, let modelName = loadedModel else {
            throw ParolaError.transcriptionFailed("Parakeet model not loaded")
        }
        if let lang = options.language, lang.lowercased() != "en" {
            throw ParolaError.unsupportedForEngine("Parakeet only supports English (got \"\(lang)\")")
        }
        if options.task == .translate {
            throw ParolaError.unsupportedForEngine("Parakeet does not support translation")
        }
        let interval = signposter.beginInterval("transcribe", "model=\(modelName, privacy: .public)")
        defer { signposter.endInterval("transcribe", interval) }

        var decoderState = TdtDecoderState.make()
        let result: ASRResult
        do {
            result = try await asr.transcribe(url, decoderState: &decoderState, language: nil)
        } catch {
            throw ParolaError.transcriptionFailed("Parakeet transcribe failed: \(error.localizedDescription)")
        }

        let segments = Self.makeSegments(from: result, includeWords: options.wordTimestamps)
        return Transcript(
            segments: segments,
            language: "en",
            modelName: modelName,
            sourceURL: url,
            durationSeconds: result.duration > 0 ? result.duration : nil
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
        do {
            return try await AsrModels.download(
                to: targetDir,
                version: version,
                progressHandler: { snapshot in
                    progress?(snapshot.fractionCompleted)
                }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ParolaError.modelDownloadFailed(model, underlying: String(describing: error))
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
