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
        // A switch lets the old model go first, so the two are never resident together.
        whisperKit = nil
        loadedModel = nil
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
            throw ParolaError.engineLoadFailed("model load failed: \(error.localizedDescription)")
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
            throw ParolaError.engineLoadFailed("model not loaded")
        }
        let interval = signposter.beginInterval("transcribe", "model=\(modelName, privacy: .public)")
        defer { signposter.endInterval("transcribe", interval) }
        handlers.onStage?(.preparingAudio)
        let samples = try await Self.loadSamples(
            url: url,
            channelMode: kit.audioInputConfig.channelMode,
            deadline: FileReadDeadline.forReading(url)
        )
        try Task.checkCancellation()
        let probed = options.language == nil
            ? await probeLanguage(kit: kit, samples: samples)
            : nil
        try Task.checkCancellation()
        let pin = WhisperLanguagePin.resolve(requested: options.language, probed: probed)
        var decoding = Self.decodingOptions(for: options, pin: pin)
        // This transcriber owns its kit, but a run abandoned after a cancel can still be decoding
        // against the same decoder while the run that took its slot installs these.
        kit.textDecoder.logitsFilters = applyInitialPrompt(
            options.initialPrompt,
            to: &decoding,
            tokenizer: kit.tokenizer,
            isModelMultilingual: kit.textDecoder.isModelMultilingual
        )

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
                if let onProgress = handlers.onProgress, let latest = Self.absolutePosition(for: segments) {
                    onProgress(latest)
                }
            }
        }
        defer { kit.segmentDiscoveryCallback = nil }

        let results = await kit.transcribe(
            audioArrays: [samples],
            decodeOptions: decoding,
            callback: nil
        )
        // Each chunk swallows its own cancellation: a cancelled run lands here as a short result.
        try Task.checkCancellation()

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
        for result in outcomes {
            detectedLanguage = result.language
            for seg in result.segments {
                segments.append(WhisperSegmentMapping.segment(seg, id: segments.count))
            }
        }

        // durationSeconds comes from the source asset, not the engine: TranscriptionSession fills it in.
        return Transcript(
            segments: segments.chronologicallyOrdered(),
            language: detectedLanguage,
            modelName: modelName,
            sourceURL: url,
            languageDetection: WhisperLanguagePin.detection(
                requested: options.language,
                probed: probed,
                ranAs: detectedLanguage,
                canDetect: kit.textDecoder.isModelMultilingual
            )
        )
    }

    /// Leans on WhisperKit's own silence/fallback defaults rather than restating them here — see
    /// `WhisperDecodingFallbackTests`, which pins this call site's output against them.
    static func decodingOptions(
        for options: TranscriptionOptions,
        pin: (language: String?, detectLanguage: Bool)
    ) -> DecodingOptions {
        DecodingOptions(
            verbose: options.verbose,
            task: options.task == .translate ? .translate : .transcribe,
            language: pin.language,
            detectLanguage: pin.detectLanguage,
            skipSpecialTokens: true,
            wordTimestamps: options.wordTimestamps,
            chunkingStrategy: .vad
        )
    }

    /// `transcribe(audioPaths:)` is this load followed by `transcribe(audioArrays:)`, and its own
    /// half of that pair is the unbounded read the wedge sampled. Doing the load here puts the
    /// largest read of the run under the same deadline as every other one.
    static func loadSamples(
        url: URL,
        channelMode: AudioInputConfig.ChannelMode,
        deadline: Duration
    ) async throws -> [Float] {
        let read = await BoundedFileRead.run(deadline: deadline) {
            try? AudioProcessor.loadAudioAsFloatArray(fromPath: url.path, channelMode: channelMode)
        }
        guard case .done(let loaded) = read else {
            throw ParolaError.fileReadTimedOut(name: url.lastPathComponent)
        }
        guard let samples = loaded, !samples.isEmpty else {
            throw ParolaError.audioLoadFailed(url, underlying: "the decoder returned no samples")
        }
        return samples
    }

    /// Reads the length back off the file header, which only a run that already failed pays for.
    private static func emptyResultFields(model: String, url: URL) -> [LogField: LogValue] {
        var fields: [LogField: LogValue] = [.model: .safe(ModelToken(model))]
        if let seconds = FileAudioSource(url: url).synchronousDuration() {
            fields[.audioSeconds] = .seconds(seconds)
        }
        return fields
    }

    /// `seek` already carries the within-chunk window offset that `start`/`end` also carry (a chunk
    /// spanning two windows would double-count it), so the batch's minimum `start` backs it out.
    static func absolutePosition(for segments: [TranscriptionSegment]) -> Double? {
        guard let windowOffset = segments.map({ Double($0.start) }).min() else { return nil }
        return segments.map { Double($0.seek) / Double(WhisperKit.sampleRate) + Double($0.end) - windowOffset }.max()
    }

    private static let languageProbeWindows = 5

    private func probeLanguage(kit: WhisperKit, samples: [Float]) async -> LanguageDetection? {
        guard kit.textDecoder.isModelMultilingual else { return nil }
        let energies = ProbeAudioExtractor.measure(samples: samples, sampleRate: Double(WhisperKit.sampleRate))
        let probe = Self.probeSamples(from: samples, energies: energies)
        guard !probe.isEmpty else { return nil }
        let windowSamples = kit.featureExtractor.windowSamples ?? Constants.defaultWindowSamples
        let offsets = Self.probeWindowOffsets(in: probe, windowSamples: windowSamples)
        // Loudest window first, so a probe cut short by cancellation has read the best evidence.
        var readings: [WhisperLanguageReading] = []
        for offset in offsets {
            if Task.isCancelled { break }
            let window = Array(probe[offset..<min(probe.count, offset + windowSamples)])
            guard !window.isEmpty, let detected = try? await kit.detectLangauge(audioArray: window) else { continue }
            readings.append(WhisperLanguageReading(
                language: detected.language,
                confidence: detected.langProbs[detected.language].map { exp(Double($0)) } ?? 0
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

    /// Windows tiling the probe, or overlapping halves when it is too short to tile twice —
    /// one reading has nothing to check itself against.
    static func probeWindowOffsets(in samples: [Float], windowSamples: Int) -> [Int] {
        let spacing = samples.count >= 2 * windowSamples ? windowSamples : windowSamples / 2
        return SpeechWindowFinder.loudestWindowOffsets(
            in: samples, windowLength: windowSamples, limit: languageProbeWindows,
            hopLength: spacing, minimumSpacing: spacing
        )
    }

    /// The loudest stretches of the whole recording back to back: a lecture whose speaker starts at
    /// minute nine used to be probed on its opening room tone.
    static func probeSamples(
        from samples: [Float],
        energies: [ProbeWindowEnergy],
        sampleRate: Double = Double(WhisperKit.sampleRate)
    ) -> [Float] {
        let ranges = ProbeWindowPlanner.pick(from: energies).map { window in
            let start = min(samples.count, Int(window.start * sampleRate))
            return start..<min(samples.count, start + Int(window.duration * sampleRate))
        }
        var probe: [Float] = []
        probe.reserveCapacity(ranges.reduce(0) { $0 + $1.count })
        for range in ranges { probe.append(contentsOf: samples[range]) }
        return probe
    }
}

struct WhisperLanguageReading: Hashable, Sendable {
    var language: String
    var confidence: Double
}

/// Weighs one language reading per probe window. A window of room tone reads as a confident
/// language all the same — Czech, Russian, whatever the noise resembles — so no single window is
/// trusted: a winner is detected once a second reading survives the confidence filter and it carries
/// a clear majority of the confidence. On its own a reading has to be near-certain to count as
/// detected; otherwise it still pins the run, but as an assumption. A close call pins nothing and
/// the run detects per chunk as it did before.
enum WhisperLanguageVote {
    static let minimumConfidence = 0.1
    static let lead = 1.25
    /// 0.85; measured on the turbo model between 0.45 (white noise) and 0.98+ (clean speech).
    static let certainty = 0.85

    static func decide(_ readings: [WhisperLanguageReading]) -> LanguageDetection? {
        var mass: [String: Double] = [:]
        var counted = 0
        for reading in readings where reading.confidence >= minimumConfidence {
            let code = reading.language.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty else { continue }
            mass[code, default: 0] += reading.confidence
            counted += 1
        }
        let ranked = mass.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        guard let best = ranked.first else { return nil }
        guard let runnerUp = ranked.dropFirst().first else {
            if counted > 1 || best.value >= certainty { return .detected(best.key) }
            return .assumed(best.key)
        }
        guard best.value >= runnerUp.value * lead else { return nil }
        return .detected(best.key)
    }
}

/// Whisper re-detects the language on every VAD chunk when `detectLanguage` is on, and a quiet
/// chunk lands anywhere — Greek inside an Italian file. One probe up front pins the whole run.
enum WhisperLanguagePin {
    static func resolve(
        requested: String?,
        probed: LanguageDetection?
    ) -> (language: String?, detectLanguage: Bool) {
        if let requested { return (requested, false) }
        if let code = probed?.code, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (code, false)
        }
        return (nil, true)
    }

    /// What the run can tell the user about its language. Nothing when they named it, and nothing
    /// from an English-only model, which was never choosing.
    static func detection(
        requested: String?,
        probed: LanguageDetection?,
        ranAs language: String,
        canDetect: Bool
    ) -> LanguageDetection? {
        guard requested == nil, canDetect else { return nil }
        if let probed, probed.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .assumed(language)
        }
        return probed ?? .assumed(language)
    }
}
