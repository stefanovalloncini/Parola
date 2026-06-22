import Foundation
import CoreML
@preconcurrency import WhisperKit
import os

/// Thin async wrapper over WhisperKit. Owns one WhisperKit instance at a time.
actor WhisperKitTranscriber: Transcriber {
    static let engineID = EngineID.whisperKit
    static let capabilities = EngineCapabilities.whisperKitDefaults

    private var whisperKit: WhisperKit?
    private var loadedModel: String?
    private var loadedComputeUnits: MLComputeUnits?
    private let modelStore: ModelStore
    private let signposter = OSSignposter(subsystem: "app.parola.core", category: "engine.whisperkit")

    init(modelStore: ModelStore) {
        self.modelStore = modelStore
    }

    func load(model: String) async throws {
        try await load(model: model, computeUnits: nil)
    }

    func load(model: String, computeUnits: MLComputeUnits?) async throws {
        if loadedModel == model, loadedComputeUnits == computeUnits, whisperKit != nil { return }
        let interval = signposter.beginInterval("load", "model=\(model, privacy: .public)")
        defer { signposter.endInterval("load", interval) }
        do {
            let folder = modelStore.installedURL(for: model).path
            let kit = try await WhisperKit(
                model: model,
                downloadBase: modelStore.directory,
                modelFolder: folder,
                computeOptions: computeUnits.map { ModelComputeOptions(audioEncoderCompute: $0, textDecoderCompute: $0) },
                verbose: false,
                logLevel: .none,
                prewarm: false,
                load: true,
                download: false
            )
            self.whisperKit = kit
            self.loadedModel = model
            self.loadedComputeUnits = computeUnits
        } catch {
            throw ParolaError.transcriptionFailed("model load failed: \(error.localizedDescription)")
        }
    }

    func unload() {
        let interval = signposter.beginInterval("unload")
        defer { signposter.endInterval("unload", interval) }
        whisperKit = nil
        loadedModel = nil
        loadedComputeUnits = nil
    }

    func loadedModelName() -> String? { loadedModel }

    static func download(
        variant: String,
        downloadBase: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        do {
            return try await WhisperKit.download(
                variant: variant,
                downloadBase: downloadBase,
                useBackgroundSession: false,
                progressCallback: { p in progress?(p.fractionCompleted) }
            )
        } catch {
            throw ParolaError.modelDownloadFailed(variant, underlying: String(describing: error))
        }
    }

    func transcribe(
        url: URL,
        options: TranscriptionOptions
    ) async throws -> Transcript {
        try await transcribe(url: url, options: options, partialHandler: nil)
    }

    func transcribe(
        url: URL,
        options: TranscriptionOptions,
        partialHandler: (@Sendable (String) -> Void)?
    ) async throws -> Transcript {
        try await transcribe(url: url, options: options, partialHandler: partialHandler, progressHandler: nil)
    }

    func transcribe(
        url: URL,
        options: TranscriptionOptions,
        partialHandler: (@Sendable (String) -> Void)?,
        progressHandler: (@Sendable (Double) -> Void)?
    ) async throws -> Transcript {
        if let requested = options.computeUnits, requested != loadedComputeUnits, let current = loadedModel {
            do {
                try await load(model: current, computeUnits: requested)
            } catch {
                unload()
                throw error
            }
        }
        guard let kit = whisperKit, let modelName = loadedModel else {
            throw ParolaError.transcriptionFailed("model not loaded")
        }
        let interval = signposter.beginInterval("transcribe", "model=\(modelName, privacy: .public)")
        defer { signposter.endInterval("transcribe", interval) }
        var decoding = DecodingOptions(
            verbose: options.verbose,
            task: options.task == .translate ? .translate : .transcribe,
            language: options.language,
            detectLanguage: options.language == nil,
            skipSpecialTokens: true,
            wordTimestamps: options.wordTimestamps,
            chunkingStrategy: options.chunkingStrategy ?? .vad
        )
        if let tokens = promptTokens(options.initialPrompt, tokenizer: kit.tokenizer) {
            decoding.promptTokens = tokens
            decoding.usePrefillPrompt = true
        }

        let builder = OSAllocatedUnfairLock(initialState: StreamingPartialBuilder())
        if partialHandler != nil || progressHandler != nil {
            kit.segmentDiscoveryCallback = { @Sendable segments in
                if let partialHandler {
                    let text = builder.withLock { state -> String in
                        for segment in segments {
                            state.add(seek: segment.seek, text: segment.text)
                        }
                        return state.text
                    }
                    partialHandler(text)
                }
                if let progressHandler, let latest = segments.map({ Double($0.end) }).max() {
                    progressHandler(latest)
                }
            }
        }
        defer { kit.segmentDiscoveryCallback = nil }

        let results = await kit.transcribe(
            audioPaths: [url.path],
            decodeOptions: decoding,
            callback: nil
        )

        guard let first = results.first, let outcomes = first else {
            throw ParolaError.transcriptionFailed("WhisperKit returned no results")
        }
        guard !outcomes.isEmpty else {
            throw ParolaError.transcriptionFailed("WhisperKit returned an empty result set")
        }

        var segments: [TranscriptSegment] = []
        var detectedLanguage = options.language ?? "auto"
        var nextID = 0
        var maxEnd: Double = 0
        for result in outcomes {
            detectedLanguage = result.language
            for seg in result.segments {
                let words = seg.words?.enumerated().map { idx, w in
                    WordTiming(
                        id: "\(nextID)-\(idx)",
                        word: w.word.trimmingCharacters(in: .whitespaces),
                        start: Double(w.start),
                        end: Double(w.end),
                        probability: Double(w.probability)
                    )
                }
                segments.append(TranscriptSegment(
                    id: nextID,
                    start: Double(seg.start),
                    end: Double(seg.end),
                    text: SpokenText.normalized(seg.text),
                    words: words
                ))
                nextID += 1
                maxEnd = max(maxEnd, Double(seg.end))
            }
        }

        return Transcript(
            segments: segments.chronologicallyOrdered(),
            language: detectedLanguage,
            modelName: modelName,
            sourceURL: url,
            durationSeconds: maxEnd > 0 ? maxEnd : nil
        )
    }
}

/// Tokenizes a user-supplied prompt into the format WhisperKit's decoder expects.
/// Returns nil when there's no prompt to tokenize or when the tokenizer isn't ready.
func promptTokens(_ prompt: String?, tokenizer: WhisperTokenizer?) -> [Int]? {
    guard let prompt, let tokenizer else { return nil }
    let trimmed = prompt.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    let tokens = tokenizer.encode(text: " " + trimmed)
        .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
    return tokens.isEmpty ? nil : tokens
}
