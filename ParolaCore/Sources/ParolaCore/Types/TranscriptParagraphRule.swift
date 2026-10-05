import Foundation

/// The paragraph and speaker-turn rule shared by the transcript pane's render, its Copy button, and the reading-script builder.
public enum TranscriptParagraphRule {
    public static let pauseSeconds: Double = 1.5

    public static func breaksParagraph(
        after previousEnd: Double?,
        start: Double,
        pause: Double = pauseSeconds
    ) -> Bool {
        guard let previousEnd else { return false }
        return start - previousEnd >= pause
    }

    public static func speakerLabel(for speaker: String?) -> String? {
        guard let speaker else { return nil }
        let flattened = speaker
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.isEmpty ? nil : flattened
    }
}
