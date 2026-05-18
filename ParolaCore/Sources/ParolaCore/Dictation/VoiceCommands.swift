import Foundation

public enum VoiceCommands {
    private static let phrases: [(phrase: String, replacement: String)] = [
        ("new paragraph", "\n\n"),
        ("new line", "\n"),
        ("question mark", "?"),
        ("exclamation mark", "!"),
        ("exclamation point", "!"),
        ("full stop", "."),
        ("period", "."),
        ("comma", ","),
        ("semicolon", ";"),
        ("colon", ":"),
    ]

    public static func applyTo(_ text: String) -> String {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var result = ""
        var index = 0
        while index < tokens.count {
            if let (replacement, consumed) = matchAt(tokens: tokens, from: index) {
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

    private static func matchAt(tokens: [String], from start: Int) -> (String, Int)? {
        for (phrase, replacement) in phrases {
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
