import Foundation

public enum VoiceCommands {
    private static let phrases: [(phrase: String, replacement: String, language: String)] = [
        ("nuovo paragrafo", "\n\n", "it"),
        ("new paragraph", "\n\n", "en"),
        ("punto interrogativo", "?", "it"),
        ("punto di domanda", "?", "it"),
        ("punto esclamativo", "!", "it"),
        ("punto e virgola", ";", "it"),
        ("a capo", "\n", "it"),
        ("new line", "\n", "en"),
        ("due punti", ":", "it"),
        ("question mark", "?", "en"),
        ("exclamation mark", "!", "en"),
        ("exclamation point", "!", "en"),
        ("full stop", ".", "en"),
        ("punto", ".", "it"),
        ("period", ".", "en"),
        ("virgola", ",", "it"),
        ("comma", ",", "en"),
        ("semicolon", ";", "en"),
        ("colon", ":", "en"),
    ]

    /// Spoken-punctuation replacement, applied only for the command set matching `language`.
    /// A nil or unsupported language applies nothing: command words are ordinary words in
    /// every other language, and auto-detect gives no basis for picking a set.
    public static func applyTo(_ text: String, language: String?) -> String {
        guard let language else { return text }
        let base = language.lowercased().prefix(2)
        let active = phrases.filter { $0.language == base }
        guard !active.isEmpty else { return text }
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var result = ""
        var index = 0
        while index < tokens.count {
            if let (replacement, consumed) = matchAt(tokens: tokens, from: index, in: active) {
                let isWhitespace = replacement.allSatisfy { $0.isWhitespace || $0.isNewline }
                result = trimTrailing(result) + replacement
                if !isWhitespace, index + consumed < tokens.count {
                    result += " "
                }
                index += consumed
            } else {
                result += tokens[index]
                if index + 1 < tokens.count {
                    result += " "
                }
                index += 1
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func matchAt(
        tokens: [String],
        from start: Int,
        in active: [(phrase: String, replacement: String, language: String)]
    ) -> (String, Int)? {
        for (phrase, replacement, _) in active {
            let words = phrase.split(separator: " ").map(String.init)
            guard start + words.count <= tokens.count else { continue }
            let matched = (0..<words.count).allSatisfy { offset in
                tokens[start + offset].caseInsensitiveCompare(words[offset]) == .orderedSame
            }
            if matched { return (replacement, words.count) }
        }
        return nil
    }

    private static func trimTrailing(_ value: String) -> String {
        var result = value
        while let last = result.last, last.isWhitespace || last.isNewline {
            result.removeLast()
        }
        return result
    }
}
