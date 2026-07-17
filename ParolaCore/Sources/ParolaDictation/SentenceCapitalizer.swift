import Foundation

public enum SentenceCapitalizer {
    public static func applyTo(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        let chars = Array(text)
        var result = ""
        var capitalizeNext = true
        for (index, char) in chars.enumerated() {
            if capitalizeNext, char.isLetter {
                result += char.uppercased()
                capitalizeNext = false
            } else {
                result.append(char)
                if char == "\n" {
                    capitalizeNext = true
                } else if char == "." || char == "?" || char == "!" {
                    // Only a break before whitespace/end counts: the dot in "example.com" isn't one.
                    let next = index + 1 < chars.count ? chars[index + 1] : " "
                    if next.isWhitespace || next.isNewline {
                        capitalizeNext = true
                    }
                } else if char.isNumber {
                    // Only a digit cancels: a leading quote or bracket stays transparent so the first letter after it still capitalizes.
                    capitalizeNext = false
                }
            }
        }
        return result
    }
}
