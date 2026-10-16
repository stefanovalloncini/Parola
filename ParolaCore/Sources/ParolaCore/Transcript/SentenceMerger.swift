import Foundation

public struct SentenceMergeLimits: Sendable {
    public var maximumGapSeconds: Double
    public var maximumWords: Int
    public var maximumSeconds: Double

    public init(
        maximumGapSeconds: Double = 1.0,
        maximumWords: Int = 16,
        maximumSeconds: Double = 8
    ) {
        self.maximumGapSeconds = maximumGapSeconds
        self.maximumWords = maximumWords
        self.maximumSeconds = maximumSeconds
    }
}

/// Joins the run-on fragments Whisper cuts mid-sentence back into sentences. A segment keeps
/// growing while it has no terminal punctuation, the next one follows closely, and the result
/// stays short enough to read.
public enum SentenceMerger {
    public static func merged(
        _ segments: [TranscriptSegment],
        limits: SentenceMergeLimits = SentenceMergeLimits()
    ) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        out.reserveCapacity(segments.count)
        for segment in segments {
            guard let open = out.last, canJoin(open, segment, limits: limits) else {
                out.append(segment)
                continue
            }
            out[out.count - 1] = join(open, segment)
        }
        return out
    }

    private static func canJoin(
        _ open: TranscriptSegment,
        _ next: TranscriptSegment,
        limits: SentenceMergeLimits
    ) -> Bool {
        guard open.speaker == next.speaker else { return false }
        guard !isNonSpeechTag(open.text), !isNonSpeechTag(next.text) else { return false }
        guard (open.words == nil) == (next.words == nil) else { return false }
        guard !endsSentence(open.text) else { return false }
        guard next.start - open.end <= limits.maximumGapSeconds else { return false }
        guard next.end - open.start <= limits.maximumSeconds else { return false }
        return wordCount(open.text) + wordCount(next.text) <= limits.maximumWords
    }

    private static func join(_ open: TranscriptSegment, _ next: TranscriptSegment) -> TranscriptSegment {
        var joined = open
        joined.end = max(open.end, next.end)
        joined.text = open.text + separator(before: next.text) + next.text
        if let openWords = open.words, let nextWords = next.words {
            joined.words = openWords + nextWords
        }
        return joined
    }

    private static func separator(before text: String) -> String {
        guard let first = text.unicodeScalars.first, tightPunctuation.contains(first) else { return " " }
        return ""
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private static func isNonSpeechTag(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if IgnoredSegments.normalized(trimmed).isEmpty { return true }
        return (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) || (trimmed.hasPrefix("(") && trimmed.hasSuffix(")"))
    }

    private static func endsSentence(_ text: String) -> Bool {
        var scalars = Array(text.unicodeScalars)
        while let last = scalars.last, closers.contains(last) {
            scalars.removeLast()
        }
        guard let last = scalars.last else { return false }
        return terminators.contains(last)
    }

    private static let terminators = CharacterSet(charactersIn: ".!?…。！？")
    private static let closers = CharacterSet(charactersIn: "\"'»”’)]}").union(.whitespacesAndNewlines)
    private static let tightPunctuation = CharacterSet(charactersIn: ",.;:!?…、。")
}
