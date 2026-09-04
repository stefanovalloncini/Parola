import Foundation
@preconcurrency import WhisperKit
import os

/// Thin async wrapper over WhisperKit. Owns one WhisperKit instance at a time.
actor WhisperKitTranscriber: Transcriber {
    static let engineID = EngineID.whisperKit
    static let capabilities = EngineCapabilities.whisperKitDefaults

    private var whisperKit: WhisperKit?
    private var loadedModel: String?
    private let modelStore: ModelStore
    private let signposter = OSSignposter(subsystem: "app.parola.core", category: "engine.whisperkit")

    init(modelStore: ModelStore) {
        self.modelStore = modelStore
    }

    func load(model: String) async throws {
        if loadedModel == model, whisperKit != nil { return }
        let interval = signposter.beginInterval("load", "model=\(model, privacy: .public)")
        defer { signposter.endInterval("load", interval) }
        let startedAt = ContinuousClock.now
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
            ParolaLog.info(
                .engineWhisperKit, "model \(ModelToken(model)) loaded",
                [.elapsed: .duration(startedAt.duration(to: .now))]
            )
        } catch {
            ParolaLog.error(
                .engineWhisperKit, "model \(ModelToken(model)) failed to load",
                [.error: .error(error)]
            )
            throw ParolaError.transcriptionFailed("model load failed: \(error.localizedDescription)")
        }
    }

    func unload() {
        let interval = signposter.beginInterval("unload")
        defer { signposter.endInterval("unload", interval) }
        whisperKit = nil
        loadedModel = nil
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
            if isCancellation(error) { throw CancellationError() }
            ParolaLog.error(
                .models, "whisperkit download failed for \(ModelToken(variant))",
                [.error: .error(error)]
            )
            throw ParolaError.modelDownloadFailed(variant, underlying: String(describing: error))
        }
    }

    func transcribe(
        url: URL,
        options: TranscriptionOptions,
        handlers: TranscribeHandlers
    ) async throws -> Transcript {
        guard let kit = whisperKit, let modelName = loadedModel else {
            ParolaLog.fault(.engineWhisperKit, "transcribe called with no model loaded")
            throw ParolaError.transcriptionFailed("model not loaded")
        }
        let interval = signposter.beginInterval("transcribe", "model=\(modelName, privacy: .public)")
        defer { signposter.endInterval("transcribe", interval) }
        handlers.onStage?(.preparingAudio)
        let probed = options.language == nil ? await probeLanguage(kit: kit, url: url) : nil
        try Task.checkCancellation()
        let pin = WhisperLanguagePin.resolve(requested: options.language, probed: probed)
        var decoding = DecodingOptions(
            verbose: options.verbose,
            task: options.task == .translate ? .translate : .transcribe,
            language: pin.language,
            detectLanguage: pin.detectLanguage,
            skipSpecialTokens: true,
            wordTimestamps: options.wordTimestamps,
            chunkingStrategy: .vad
        )
        if let tokens = promptTokens(options.initialPrompt, tokenizer: kit.tokenizer) {
            decoding.promptTokens = tokens
            decoding.usePrefillPrompt = true
        }

        struct DiscoveryState {
            var builder = StreamingPartialBuilder()
            var sawFirstSegments = false
        }
        let discovery = OSAllocatedUnfairLock(initialState: DiscoveryState())
        if !handlers.observesNothing {
            kit.segmentDiscoveryCallback = { @Sendable segments in
                let (isFirst, text) = discovery.withLock { state -> (Bool, String?) in
                    let isFirst = !state.sawFirstSegments
                    state.sawFirstSegments = true
                    guard handlers.onPartial != nil else { return (isFirst, nil) }
                    for segment in segments {
                        state.builder.add(seek: segment.seek, text: segment.text)
                    }
                    return (isFirst, state.builder.tail())
                }
                if isFirst {
                    handlers.onStage?(.transcribing)
                }
                if let onPartial = handlers.onPartial, let text {
                    onPartial(text)
                }
                if let onProgress = handlers.onProgress, let latest = segments.map({ Double($0.end) }).max() {
                    onProgress(latest)
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
            ParolaLog.error(
                .engineWhisperKit, "engine returned no results",
                Self.emptyResultFields(model: modelName, url: url)
            )
            throw ParolaError.transcriptionFailed("WhisperKit returned no results")
        }
        guard !outcomes.isEmpty else {
            ParolaLog.error(
                .engineWhisperKit, "engine returned an empty result set",
                Self.emptyResultFields(model: modelName, url: url)
            )
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

    /// Reads the length back off the file header, which only a run that already failed pays for.
    private static func emptyResultFields(model: String, url: URL) -> [LogField: LogValue] {
        var fields: [LogField: LogValue] = [.model: .safe(ModelToken(model))]
        if let seconds = FileAudioSource(url: url).synchronousDuration() {
            fields[.audioSeconds] = .seconds(seconds)
        }
        return fields
    }

    private static let languageProbePrefixSeconds: Double = 300
    private static let languageProbeWindows = 5

    private func probeLanguage(kit: WhisperKit, url: URL) async -> String? {
        guard kit.textDecoder.isModelMultilingual else { return nil }
        guard let samples = probeSamples(url: url), !samples.isEmpty else { return nil }
        let windowSamples = kit.featureExtractor.windowSamples ?? Constants.defaultWindowSamples
        let offsets = SpeechWindowFinder.loudestWindowOffsets(
            in: samples, windowLength: windowSamples, limit: Self.languageProbeWindows
        )
        var readings: [WhisperLanguageReading] = []
        for offset in offsets {
            if Task.isCancelled { break }
            let window = Array(samples[offset..<min(samples.count, offset + windowSamples)])
            guard !window.isEmpty, let probe = try? await kit.detectLangauge(audioArray: window) else { continue }
            readings.append(WhisperLanguageReading(
                language: probe.language,
                confidence: probe.langProbs[probe.language].map { exp(Double($0)) } ?? 0
            ))
        }
        let decided = WhisperLanguageVote.decide(readings)
        if decided == nil {
            ParolaLog.info(
                .engineWhisperKit, "language probe inconclusive", [.count: .int(readings.count)]
            )
        }
        return decided
    }

    private func probeSamples(url: URL) -> [Float]? {
        guard let buffer = try? AudioProcessor.loadAudio(
            fromPath: url.path,
            startTime: 0,
            endTime: Self.languageProbePrefixSeconds
        ) else { return nil }
        return AudioProcessor.convertBufferToArray(buffer: buffer)
    }
}

struct WhisperLanguageReading: Hashable, Sendable {
    var language: String
    var confidence: Double
}

/// Weighs one language reading per probe window. A window of room tone reads as a confident
/// language all the same — Czech, Russian, whatever the noise resembles — so no single window is
/// trusted: the winner has to carry a clear majority of the confidence, otherwise the run is left
/// to detect per chunk as it did before.
enum WhisperLanguageVote {
    static let minimumConfidence = 0.1
    static let lead = 1.25

    static func decide(_ readings: [WhisperLanguageReading]) -> String? {
        var mass: [String: Double] = [:]
        for reading in readings where reading.confidence >= minimumConfidence {
            let code = reading.language.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty else { continue }
            mass[code, default: 0] += reading.confidence
        }
        let ranked = mass.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        guard let best = ranked.first else { return nil }
        guard ranked.count == 1 || best.value >= ranked[1].value * lead else { return nil }
        return best.key
    }
}

/// Whisper re-detects the language on every VAD chunk when `detectLanguage` is on, and a quiet
/// chunk lands anywhere — Greek inside an Italian file. One probe up front pins the whole run.
enum WhisperLanguagePin {
    static func resolve(
        requested: String?,
        probed: String?
    ) -> (language: String?, detectLanguage: Bool) {
        if let requested { return (requested, false) }
        if let probed, !probed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (probed, false)
        }
        return (nil, true)
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
