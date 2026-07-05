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
        let wrapped = CaptionWrapper.wrap(text, length: captionLength)
        guard !wrapped.isEmpty else { return [] }

        var found: [Issue] = []
        if let limit = captionLength.maxCharsPerLine,
           wrapped.split(separator: "\n").contains(where: { $0.count > limit }) {
            found.append(.lineTooLong(limit: limit))
        }
        if duration > 0 {
            let characters = wrapped.count(where: { !$0.isNewline })
            let rate = Double(characters) / duration
            if rate > maxCharactersPerSecond {
                found.append(.tooFast(charactersPerSecond: Int(rate.rounded())))
            }
        }
        if duration < minimumDuration {
            found.append(.tooShort)
        }
        return found
    }

    public static func issues(for segment: TranscriptSegment, captionLength: CaptionLength) -> [Issue] {
        issues(text: segment.text, duration: segment.duration, captionLength: captionLength)
    }
}
