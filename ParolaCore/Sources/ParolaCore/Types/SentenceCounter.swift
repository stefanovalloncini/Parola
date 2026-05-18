import Foundation

public enum SentenceCounter {
    public static func count(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        var sentences = 0
        var insideSentence = false
        var inDigit = false
        for char in trimmed {
            if char.isWhitespace || char.isNewline {
                inDigit = false
                continue
            }
            if char == "." || char == "!" || char == "?" {
                if char == "." && inDigit { continue }
                if insideSentence {
                    sentences += 1
                    insideSentence = false
                }
                inDigit = false
            } else {
                insideSentence = true
                inDigit = char.isNumber
            }
        }
        if insideSentence { sentences += 1 }
        return sentences
    }
}
