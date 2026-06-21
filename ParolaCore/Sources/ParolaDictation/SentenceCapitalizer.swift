import Foundation

public enum SentenceCapitalizer {
    public static func applyTo(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        var result = ""
        var capitalizeNext = true
        for char in text {
            if capitalizeNext, char.isLetter {
                result += char.uppercased()
                capitalizeNext = false
            } else {
                result.append(char)
                if char == "." || char == "?" || char == "!" || char == "\n" {
                    capitalizeNext = true
                } else if !char.isWhitespace {
                    capitalizeNext = false
                }
            }
        }
        return result
    }
}
