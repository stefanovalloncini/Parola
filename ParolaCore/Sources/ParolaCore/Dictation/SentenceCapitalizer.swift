import Foundation

public enum SentenceCapitalizer {
    public static func applyTo(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        var characters = Array(text)
        var capitalizeNext = true
        for index in characters.indices {
            let char = characters[index]
            if capitalizeNext, char.isLetter {
                characters[index] = Character(char.uppercased())
                capitalizeNext = false
            } else if char == "." || char == "?" || char == "!" || char == "\n" {
                capitalizeNext = true
            } else if !char.isWhitespace {
                capitalizeNext = false
            }
        }
        return String(characters)
    }
}
