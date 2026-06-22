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
                } else if char.isNumber {
                    // Only a digit cancels: a leading quote or bracket stays transparent so the first letter after it still capitalizes.
                    capitalizeNext = false
                }
            }
        }
        return result
    }
}
