import Foundation

/// Normalizes a raw ASR segment's text: trims surrounding whitespace and collapses to "" when
/// the text carries no spoken content — only punctuation or symbols, as Whisper emits for silence
/// ("..."). Returning "" lets the existing empty-segment-drop path remove the non-speech artifact.
enum SpokenText {
    static func normalized(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains(where: { $0.isLetter || $0.isNumber }) ? trimmed : ""
    }
}
