import Foundation

#if canImport(Speech)
import Speech
#endif

extension AppleSpeechCaptionBackend {
    static let live = AppleSpeechCaptionBackend(
        prepare: { locale, progress in
            #if canImport(Speech)
            guard #available(macOS 26.0, iOS 26.0, *) else { throw LiveSpeechCaption.needsNewerOS }
            return try await LiveSpeechCaption.prepare(locale, progress: progress)
            #else
            throw LiveSpeechCaption.needsNewerOS
            #endif
        },
        makeAnalyzer: { locale in
            #if canImport(Speech)
            guard #available(macOS 26.0, iOS 26.0, *) else { throw LiveSpeechCaption.needsNewerOS }
            return try await LiveSpeechCaption.makeAnalyzer(locale)
            #else
            throw LiveSpeechCaption.needsNewerOS
            #endif
        }
    )
}

enum LiveSpeechCaption {
    static let needsNewerOS = ParolaError.unsupportedForEngine("Apple SpeechAnalyzer requires macOS 26 or iOS 26.")

    /// The language as the person reads it, without its region, falling back to the identifier.
    static func languageName(_ locale: Locale) -> String {
        let code = locale.language.languageCode?.identifier ?? ""
        return Locale.current.localizedString(forLanguageCode: code) ?? locale.identifier
    }

    /// Only for a locale or audio format Speech has no model for.
    static func noModel(for locale: Locale) -> ParolaError {
        .unsupportedForEngine(FixedFailureText.appleSpeechNoModel(languageName(locale)))
    }

    static func downloadFailed(for locale: Locale) -> ParolaError {
        .unsupportedForEngine(FixedFailureText.appleSpeechDownloadFailed(languageName(locale)))
    }

    static let startFailed = ParolaError.unsupportedForEngine(FixedFailureText.appleSpeechCouldNotStart)
}

#if canImport(Speech)
@available(macOS 26.0, iOS 26.0, *)
extension LiveSpeechCaption {
    private static func transcriber(for locale: Locale) -> SpeechTranscriber {
        // Without the preset's fast results, volatile text lands in ~4 s bursts, a median 1.9 s behind the speaker.
        SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
    }

    static func prepare(_ requested: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> Locale {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            ParolaLog.notice(.engineAppleSpeech, "captions locale unsupported")
            throw noModel(for: requested)
        }
        let transcriber = transcriber(for: locale)
        let request: AssetInstallationRequest?
        do {
            request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            ParolaLog.error(.engineAppleSpeech, "captions asset request failed", [.error: .error(error)])
            throw startFailed
        }
        if let request {
            try await AssetInstall.run(LiveAssetRequest(request), locale: locale, progress: progress)
        }
        return locale
    }

    static func makeAnalyzer(_ locale: Locale) async throws -> any CaptionAnalyzing {
        let transcriber = transcriber(for: locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
              let converter = AnalyzerBufferConverter(target: format)
        else { throw noModel(for: locale) }
        let (inputs, input) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(inputChunkLimit))
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (recognitions, output) = AsyncThrowingStream<CaptionRecognition, any Error>.makeStream()
        let forwarding = Task {
            do {
                for try await result in transcriber.results {
                    output.yield(CaptionRecognition(
                        text: String(result.text.characters),
                        start: result.range.start.seconds,
                        end: result.range.end.seconds,
                        isFinal: result.isFinal,
                        runs: result.text.runs.map {
                            CaptionRecognition.Run(
                                text: String(result.text[$0.range].characters),
                                start: $0.audioTimeRange?.start.seconds,
                                end: $0.audioTimeRange?.end.seconds
                            )
                        }
                    ))
                }
                output.finish()
            } catch {
                output.finish(throwing: error)
            }
        }
        do {
            try await analyzer.start(inputSequence: inputs)
        } catch {
            ParolaLog.error(.engineAppleSpeech, "captions analyzer failed to start", [.error: .error(error)])
            forwarding.cancel()
            input.finish()
            await AnalyzerCancellation.stop(analyzer)
            throw startFailed
        }
        return LiveCaptionAnalyzer(
            analyzer: analyzer, converter: converter, input: input, recognitions: recognitions, output: output, forwarding: forwarding
        )
    }
}

@available(macOS 26.0, iOS 26.0, *)
private struct LiveAssetRequest: AssetInstalling {
    let request: AssetInstallationRequest

    init(_ request: AssetInstallationRequest) { self.request = request }

    var fractionCompleted: Double { request.progress.fractionCompleted }
    func downloadAndInstall() async throws { try await request.downloadAndInstall() }
    func cancel() { request.progress.cancel() }
}

/// A minute of the capture's 100 ms chunks: past that the analyzer has stalled, and the session fails.
private let inputChunkLimit = 600

@available(macOS 26.0, iOS 26.0, *)
private final class LiveCaptionAnalyzer: CaptionAnalyzing {
    let recognitions: AsyncThrowingStream<CaptionRecognition, any Error>
    private let analyzer: SpeechAnalyzer
    private let converter: AnalyzerBufferConverter
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let output: AsyncThrowingStream<CaptionRecognition, any Error>.Continuation
    private let forwarding: Task<Void, Never>

    init(
        analyzer: SpeechAnalyzer, converter: AnalyzerBufferConverter, input: AsyncStream<AnalyzerInput>.Continuation,
        recognitions: AsyncThrowingStream<CaptionRecognition, any Error>,
        output: AsyncThrowingStream<CaptionRecognition, any Error>.Continuation, forwarding: Task<Void, Never>
    ) {
        self.output = output
        self.analyzer = analyzer
        self.converter = converter
        self.input = input
        self.recognitions = recognitions
        self.forwarding = forwarding
    }

    func feed(_ samples: [Float]) -> Bool {
        guard let buffer = converter.buffer(from: samples) else { return true }
        if case .dropped = input.yield(AnalyzerInput(buffer: buffer)) { return false }
        return true
    }

    func finalize() async throws {
        input.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
    }

    func cancel() async {
        output.finish()
        input.finish()
        forwarding.cancel()
        await AnalyzerCancellation.stop(analyzer)
    }
}
#endif
