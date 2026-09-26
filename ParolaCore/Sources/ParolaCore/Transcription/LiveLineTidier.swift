import Foundation

/// Tidies confirmed live lines one at a time, for a surface that prints them as they land: the
/// built-in hallucination filter and the post-processor, keyed on the pinned language or else on
/// what the take reads as so far. Sentence merging needs the whole take, so it stays with the
/// finished transcript.
public struct LiveLineTidier: Sendable {
    private let pinnedLanguage: String?
    private let postProcessor: TranscriptPostProcessor
    private var heard: [TranscriptSegment] = []

    public init(language: String?, postProcessor: TranscriptPostProcessor = .orthographyOnly) {
        self.pinnedLanguage = language
        self.postProcessor = postProcessor
    }

    /// The line as it should print, or nil when it is filler nobody said.
    public mutating func tidy(_ segment: TranscriptSegment) -> TranscriptSegment? {
        var line = segment
        line.text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.text.isEmpty, !IgnoredSegments.applyBuiltInDefaults(to: [line]).isEmpty else { return nil }
        heard.append(line)
        let language = pinnedLanguage ?? TextLanguageGuess.dominantLanguage(of: heard) ?? "auto"
        let processed = postProcessor.apply(Transcript(segments: [line], language: language, modelName: ""))
        return processed.segments.first
    }
}
