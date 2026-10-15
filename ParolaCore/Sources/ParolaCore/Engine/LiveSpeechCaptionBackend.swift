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

    static func noModel(for locale: Locale) -> ParolaError {
        .unsupportedForEngine(FixedFailureText.appleSpeechNoModel(locale.identifier))
    }

    static func downloadFailed(for locale: Locale) -> ParolaError {
        .unsupportedForEngine(FixedFailureText.appleSpeechDownloadFailed(locale.identifier))
    }
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
        do {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return locale }
            let watcher = Task {
                while !Task.isCancelled {
                    progress(request.progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { watcher.cancel() }
            try await request.downloadAndInstall()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            ParolaLog.error(.engineAppleSpeech, "captions asset install failed", [.error: .error(error)])
            throw downloadFailed(for: locale)
        }
        return locale
    }

    static func makeAnalyzer(_ locale: Locale) async throws -> any CaptionAnalyzing {
        let transcriber = transcriber(for: locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
              let converter = AnalyzerBufferConverter(target: format)
        else { throw noModel(for: locale) }
        let (inputs, input) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (recognitions, output) = AsyncThrowingStream<CaptionRecognition, any Error>.makeStream()
        let forwarding = Task {
            do {
                for try await result in transcriber.results {
                    output.yield(CaptionRecognition(
                        text: String(result.text.characters),
                        start: result.range.start.seconds,
                        end: result.range.end.seconds,
                        isFinal: result.isFinal
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
            forwarding.cancel()
            input.finish()
            await AnalyzerCancellation.stop(analyzer)
            throw noModel(for: locale)
        }
        return LiveCaptionAnalyzer(
            analyzer: analyzer, converter: converter, input: input, recognitions: recognitions, forwarding: forwarding
        )
    }
}

@available(macOS 26.0, iOS 26.0, *)
private final class LiveCaptionAnalyzer: CaptionAnalyzing {
    let recognitions: AsyncThrowingStream<CaptionRecognition, any Error>
    private let analyzer: SpeechAnalyzer
    private let converter: AnalyzerBufferConverter
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let forwarding: Task<Void, Never>

    init(
        analyzer: SpeechAnalyzer, converter: AnalyzerBufferConverter, input: AsyncStream<AnalyzerInput>.Continuation,
        recognitions: AsyncThrowingStream<CaptionRecognition, any Error>, forwarding: Task<Void, Never>
    ) {
        self.analyzer = analyzer
        self.converter = converter
        self.input = input
        self.recognitions = recognitions
        self.forwarding = forwarding
    }

    func feed(_ samples: [Float]) {
        guard let buffer = converter.buffer(from: samples) else { return }
        input.yield(AnalyzerInput(buffer: buffer))
    }

    func finalize() async throws {
        input.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
    }

    func cancel() async {
        input.finish()
        forwarding.cancel()
        await AnalyzerCancellation.stop(analyzer)
    }
}
#endif
