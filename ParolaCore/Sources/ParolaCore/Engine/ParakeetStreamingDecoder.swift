import Foundation
@preconcurrency import FluidAudio
@preconcurrency import WhisperKit

/// Live captions on Parakeet: each decode re-reads the loop's unconfirmed window in one encoder pass.
enum ParakeetStreamingDecoder {
    typealias Recognize = @Sendable ([Float]) async throws -> ASRResult

    private static let sampleRate = Double(WhisperKit.sampleRate)

    /// Refuses what Parakeet can't caption, before any download or capture starts.
    static func admit(_ options: TranscriptionOptions, model: String) throws {
        if let language = options.language, !ParakeetTranscriber.accepts(language: language, forModel: model) {
            ParolaLog.notice(.streaming, "rejected language \(LanguageToken(language))")
            throw ParakeetTranscriber.languageRejection(language, model: model)
        }
        if options.task == .translate {
            ParolaLog.notice(.streaming, "rejected translate: unsupported")
            throw ParakeetTranscriber.translationRejection
        }
        ParolaLog.info(.streaming, "streaming session starting on parakeet", [.model: .safe(ModelToken(model))])
    }

    static func over(lease: StreamingModelLease, options: TranscriptionOptions) throws -> StreamingRealtimeLoop.Decoder {
        guard case .parakeet(let models) = lease.payload else {
            throw ParolaError.engineLoadFailed("Parakeet captions were handed another engine's model")
        }
        let asr = AsrManager(config: .default, models: models)
        let hint = ParakeetTranscriber.scriptHint(for: options.language)
        return decoder(options: options) { samples in
            // The decoder holds the lease too, so a session dropped mid-take can't let the models unload under a decode.
            defer { withExtendedLifetime(lease) {} }
            var state = TdtDecoderState.make()
            return try await asr.transcribe(samples, decoderState: &state, language: hint)
        }
    }

    static func decoder(options: TranscriptionOptions, recognize: @escaping Recognize) -> StreamingRealtimeLoop.Decoder {
        let decoding = DecodingOptions(language: options.language, wordTimestamps: options.wordTimestamps)
        let language = options.language ?? "en"
        let includeWords = options.wordTimestamps
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: WhisperKit.sampleRate)
        return StreamingRealtimeLoop.Decoder(options: decoding) { samples, decodeOptions, _ in
            let requested = Int(Double(decodeOptions.clipTimestamps.first ?? 0) * sampleRate)
            let clip = max(min(samples.count, requested), samples.count - ASRConstants.maxModelSamples)
            guard samples.count - clip >= minimum else {
                return TranscriptionResult(text: "", segments: [], language: language, timings: TranscriptionTimings())
            }
            let result = try await recognize(Array(samples[clip...]))
            let shift = Float(Double(clip) / sampleRate)
            let segments = ParakeetTranscriber.makeSegments(from: result, includeWords: includeWords, splitting: .captions)
                .map { shifted($0, by: shift) }
            return TranscriptionResult(
                text: segments.map(\.text).joined(separator: " "),
                segments: segments,
                language: language,
                timings: TranscriptionTimings()
            )
        }
    }

    private static func shifted(_ segment: TranscriptSegment, by shift: Float) -> TranscriptionSegment {
        TranscriptionSegment(
            id: segment.id,
            start: Float(segment.start) + shift,
            end: Float(segment.end) + shift,
            text: segment.text,
            words: segment.words?.map {
                .init(
                    word: $0.word, tokens: [], start: Float($0.start) + shift, end: Float($0.end) + shift,
                    probability: Float($0.probability)
                )
            }
        )
    }
}
