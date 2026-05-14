import Foundation
import WhisperKit

/// Thin async wrapper over WhisperKit. Owns one WhisperKit instance at a time.
actor WhisperKitTranscriber {
    private var whisperKit: WhisperKit?
    private var loadedModel: String?
    private let modelStore: ModelStore

    init(modelStore: ModelStore) {
        self.modelStore = modelStore
    }

    func load(model: String) async throws {
        if loadedModel == model, whisperKit != nil { return }
        do {
            let folder = modelStore.installedURL(for: model).path
            let kit = try await WhisperKit(
                model: model,
                downloadBase: modelStore.directory,
                modelFolder: folder,
                verbose: false,
                logLevel: .none,
                prewarm: false,
                load: true,
                download: false
            )
            self.whisperKit = kit
            self.loadedModel = model
        } catch {
            throw ParolaError.transcriptionFailed("model load failed: \(error.localizedDescription)")
        }
    }

    func unload() {
        whisperKit = nil
        loadedModel = nil
    }

    func loadedModelName() -> String? { loadedModel }

    func transcribe(
        url: URL,
        options: TranscriptionOptions
    ) async throws -> Transcript {
        guard let kit = whisperKit, let modelName = loadedModel else {
            throw ParolaError.transcriptionFailed("model not loaded")
        }
        var decoding = DecodingOptions(
            verbose: options.verbose,
            task: options.task == .translate ? .translate : .transcribe,
            language: options.language,
            detectLanguage: options.language == nil,
            skipSpecialTokens: true,
            wordTimestamps: options.wordTimestamps,
            chunkingStrategy: .vad
        )
        if let tokens = promptTokens(options.initialPrompt, tokenizer: kit.tokenizer) {
            decoding.promptTokens = tokens
            decoding.usePrefillPrompt = true
        }

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
                    text: seg.text,
                    words: words
                ))
                nextID += 1
                maxEnd = max(maxEnd, Double(seg.end))
            }
        }

        return Transcript(
            segments: segments,
            language: detectedLanguage,
            modelName: modelName,
            sourceURL: url,
            durationSeconds: maxEnd > 0 ? maxEnd : nil
        )
    }
}

/// Tokenizes a user-supplied prompt into the format WhisperKit's decoder expects.
/// Returns nil when the prompt is missing, empty, or the tokenizer isn't ready.
func promptTokens(_ prompt: String?, tokenizer: WhisperTokenizer?) -> [Int]? {
    guard let prompt, let tokenizer else { return nil }
    let trimmed = prompt.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    let tokens = tokenizer.encode(text: " " + trimmed)
        .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
    return tokens.isEmpty ? nil : tokens
}
