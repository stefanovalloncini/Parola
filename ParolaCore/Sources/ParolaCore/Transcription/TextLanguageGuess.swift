import Foundation
import NaturalLanguage

enum TextLanguageGuess {
    /// ISO 639-1 code of the dominant language, nil when the text carries no usable signal.
    static func dominantLanguage(of text: String) -> String? {
        let sample = String(text.prefix(4000))
        guard sample.contains(where: \.isLetter) else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let language = recognizer.dominantLanguage else { return nil }
        return String(language.rawValue.prefix(2))
    }
}
