import Foundation
import ParolaCore

enum TranscriptDerive {
    /// Up to this many segments the derive fits inside a frame, so it runs inline and the list never lands late.
    static let synchronousCap = 200

    /// Silence at least this long between two segments reads as a new paragraph in the continuous transcript.
    static let paragraphPauseSeconds: TimeInterval = 1.5
}

/// The paragraph rule shared by the continuous transcript's render and the Copy button's pasteboard write.
enum TranscriptParagraphs {
    static func breaksParagraph(
        after previousEnd: Double?,
        start: Double,
        pause: TimeInterval = TranscriptDerive.paragraphPauseSeconds
    ) -> Bool {
        guard let previousEnd else { return false }
        return start - previousEnd >= pause
    }

    /// Paragraphs separated by a blank line, speaker runs opened by their label — what a select-all of the pane copies.
    nonisolated static func plainText(
        segments: [TranscriptSegment],
        includeSpeakerLabels: Bool,
        pause: TimeInterval = TranscriptDerive.paragraphPauseSeconds
    ) -> String {
        var out = ""
        var shownSpeaker: String?
        var lastEnd: Double?

        for seg in segments {
            let body = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let pauseBreak = breaksParagraph(after: lastEnd, start: seg.start, pause: pause)
            lastEnd = seg.end
            let label = includeSpeakerLabels ? SegmentCard.speakerLabel(for: seg.speaker) : nil
            if let label, label != shownSpeaker {
                if !out.isEmpty { out += "\n\n" }
                out += label + "\n"
                shownSpeaker = label
            } else if pauseBreak, !out.isEmpty {
                out += "\n\n"
            } else if !out.isEmpty {
                out += " "
            }
            out += body
        }
        return out
    }
}
