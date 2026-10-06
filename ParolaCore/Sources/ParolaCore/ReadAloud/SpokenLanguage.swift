import Foundation

/// Decides which language a reading should be spoken in, for a transcript, its translation or its summary.
public enum SpokenLanguage {
    /// Trims the code and rejects the "auto"/"unknown" sentinels (case-insensitively); nil for nil, empty or a sentinel.
    public static func realCode(_ code: String?) -> String? {
        guard let raw = code else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        guard lowered != "auto", lowered != "unknown" else { return nil }
        return trimmed
    }

    /// The transcript's own language when it is real and wasn't a guess; otherwise the dominant language of its text; otherwise the UI's own language.
    public static func forTranscript(_ transcript: Transcript, uiLanguage: String) -> String {
        if transcript.languageDetection?.isAssumed != true, let real = realCode(transcript.language) {
            return real
        }
        if let guess = TextLanguageGuess.dominantLanguage(of: transcript.segments) {
            return guess
        }
        return uiLanguage
    }

    /// The language a translation is read in: its own target language.
    public static func forTranslation(targetLanguage: String) -> String {
        targetLanguage
    }

    /// The dominant language of a summary's text; otherwise of its text, chapter titles and action items together; otherwise the transcript's language.
    public static func forSummary(
        text: String,
        chapterTitles: [String],
        actionItems: [String],
        transcriptLanguage: String
    ) -> String {
        let stripped = ReadingScriptBuilder.strippingMarkdown(text)
        if let guess = TextLanguageGuess.dominantLanguage(of: stripped) {
            return guess
        }
        let combined = ([stripped] + chapterTitles + actionItems).joined(separator: " ")
        if let guess = TextLanguageGuess.dominantLanguage(of: combined) {
            return guess
        }
        return transcriptLanguage
    }

    /// The base language a voice is keyed by: lowercased `Locale.Language` reduction (en-GB, zh-Hant, pt-BR all reduce), except "yue" which stays itself.
    public static func baseCode(_ code: String) -> String {
        let lowered = code.lowercased()
        if lowered == "yue" { return "yue" }
        guard let base = Locale.Language(identifier: lowered).languageCode?.identifier else {
            return lowered
        }
        return base.lowercased()
    }
}
