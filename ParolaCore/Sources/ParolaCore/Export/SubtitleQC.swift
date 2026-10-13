import Foundation

/// Flags segments that would make poor subtitle cues: a line over the caption limit,
/// a reading speed above 21 characters per second, or a duration under 0.7 seconds.
public enum SubtitleQC {
    public static let maxCharactersPerSecond: Double = 21
    public static let minimumDuration: Double = 0.7

    public enum Issue: Sendable, Equatable {
        case lineTooLong(limit: Int)
        case tooFast(charactersPerSecond: Int)
        case tooShort
    }

    public static func issues(text: String, duration: Double, captionLength: CaptionLength) -> [Issue] {
        issues(for: TranscriptSegment(id: 0, start: 0, end: duration, text: text), captionLength: captionLength)
    }

    public static func issues(
        for segment: TranscriptSegment, captionLength: CaptionLength, speaker: String? = nil, translation: String? = nil
    ) -> [Issue] {
        guard let limit = captionLength.maxCharsPerLine else { return asIsIssues(text: segment.text, duration: segment.duration) }
        let part = CaptionSource.Part(
            text: segment.text, start: segment.start, end: segment.end, words: segment.words, translation: translation
        )
        return judge([CaptionSource(parts: [part], speaker: speaker, tag: segment.id)], limit: limit)[segment.id] ?? []
    }

    /// Each segment judged by the cues an export would write for it, set among the segments around it.
    /// `showsSpeakers` and `translations` say whether the export puts the speaker label and a translation in the cue.
    public static func issues(
        forSegments segments: [TranscriptSegment], captionLength: CaptionLength, showsSpeakers: Bool = false,
        translations: [Int: String] = [:], language: String? = nil
    ) -> [Int: [Issue]] {
        guard let limit = captionLength.maxCharsPerLine else {
            return segments.reduce(into: [:]) { found, segment in
                let issues = asIsIssues(text: segment.text, duration: segment.duration)
                if !issues.isEmpty { found[segment.id] = issues }
            }
        }
        let sources = segments.map { segment -> CaptionSource in
            let part = CaptionSource.Part(
                text: segment.text, start: segment.start, end: segment.end, words: segment.words,
                translation: translations[segment.id], language: language
            )
            let speaker = showsSpeakers ? Format.presentationSpeakerLabel(segment.speaker) : nil
            return CaptionSource(parts: [part], speaker: speaker, tag: segment.id)
        }
        return judge(sources, limit: limit)
    }

    private static func judge(_ sources: [CaptionSource], limit: Int) -> [Int: [Issue]] {
        let label: (String) -> String = { "\($0): " }
        guard let cues = try? CaptionCues.cues(for: sources, breaker: .characters(limit), speakerPrefix: label) else { return [:] }
        var byTag: [Int: [CaptionCue]] = [:]
        for cue in cues { byTag[cue.tag, default: []].append(cue) }

        var found: [Int: [Issue]] = [:]
        for (tag, own) in byTag {
            var issues: [Issue] = []
            var widest = 0
            var fastest = 0.0
            for cue in own {
                let lines = cue.shownLines(speakerPrefix: label)
                widest = max(widest, lines.map { CaptionBreaker.columns(of: $0) }.max() ?? 0)
                let seconds = cue.end - cue.start
                if seconds > 0 { fastest = max(fastest, Double(lines.reduce(0) { $0 + $1.count }) / seconds) }
            }
            if widest > limit { issues.append(.lineTooLong(limit: limit)) }
            if fastest > maxCharactersPerSecond { issues.append(.tooFast(charactersPerSecond: Int(fastest.rounded()))) }
            if own.contains(where: { $0.end - $0.start < minimumDuration }) { issues.append(.tooShort) }
            if !issues.isEmpty { found[tag] = issues }
        }
        return found
    }

    private static func asIsIssues(text: String, duration: Double) -> [Issue] {
        let wrapped = CaptionWrapper.wrap(text, length: .none)
        guard !wrapped.isEmpty else { return [] }
        var found: [Issue] = []
        if duration > 0 {
            let rate = Double(wrapped.count(where: { !$0.isNewline })) / duration
            if rate > maxCharactersPerSecond { found.append(.tooFast(charactersPerSecond: Int(rate.rounded()))) }
        }
        if duration < minimumDuration { found.append(.tooShort) }
        return found
    }
}
