import Foundation

public enum SentenceCounter {
    public static func count(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        var sentences = 0
        var insideSentence = false
        var previousWasDigit = false
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let char = trimmed[index]
            let next = trimmed.index(after: index)
            index = next
            if char.isWhitespace || char.isNewline {
                previousWasDigit = false
                continue
            }
            if char == "." || char == "!" || char == "?" {
                let nextIsDigit = next < trimmed.endIndex && trimmed[next].isNumber
                if char == "." && previousWasDigit && nextIsDigit {
                    previousWasDigit = false
                    continue
                }
                if insideSentence {
                    sentences += 1
                    insideSentence = false
                }
                previousWasDigit = false
            } else {
                insideSentence = true
                previousWasDigit = char.isNumber
            }
        }
        if insideSentence { sentences += 1 }
        return sentences
    }
}
