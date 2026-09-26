import Foundation

public enum SentenceCounter {
    public static func count(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var tally = SentenceTally()
        for character in trimmed {
            tally.feed(character, kind: CharacterKind(character))
        }
        return tally.finish()
    }
}

/// The three questions the text counters ask of every character. ASCII skips the Unicode property
/// lookups, which otherwise cost most of a walk over the text.
struct CharacterKind {
    let isWhitespace: Bool
    let isDigit: Bool
    let isLetterOrDigit: Bool

    init(_ character: Character) {
        if let ascii = character.asciiValue {
            isWhitespace = ascii == 0x20 || (0x09...0x0D).contains(ascii)
            isDigit = (0x30...0x39).contains(ascii)
            isLetterOrDigit = isDigit || (0x41...0x5A).contains(ascii) || (0x61...0x7A).contains(ascii)
        } else {
            isWhitespace = character.isWhitespace
            isDigit = character.isNumber
            isLetterOrDigit = isDigit || character.isLetter
        }
    }
}

/// Counts sentences a character at a time. A terminator waits for the next character, so "3.5" stays one number.
struct SentenceTally {
    private var sentences = 0
    private var insideSentence = false
    private var previousWasDigit = false
    private var pendingTerminator = false
    private var pendingDecimalPoint = false

    mutating func feed(_ character: Character, kind: CharacterKind) {
        if pendingTerminator { closeTerminator(nextIsDigit: kind.isDigit) }
        if kind.isWhitespace {
            previousWasDigit = false
            return
        }
        if character == "." || character == "!" || character == "?" {
            pendingTerminator = true
            pendingDecimalPoint = character == "." && previousWasDigit
            return
        }
        insideSentence = true
        previousWasDigit = kind.isDigit
    }

    mutating func finish() -> Int {
        if pendingTerminator { closeTerminator(nextIsDigit: false) }
        return sentences + (insideSentence ? 1 : 0)
    }

    private mutating func closeTerminator(nextIsDigit: Bool) {
        pendingTerminator = false
        previousWasDigit = false
        if pendingDecimalPoint, nextIsDigit { return }
        if insideSentence {
            sentences += 1
            insideSentence = false
        }
    }
}
