import Foundation
import NaturalLanguage

enum TextLanguageGuess {
    private static let sampleLength = 4000

    /// ISO 639-1 code of the dominant language, nil when the text carries no usable signal.
    static func dominantLanguage(of text: String) -> String? {
        let sample = String(text.prefix(sampleLength))
        guard sample.contains(where: \.isLetter) else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let language = recognizer.dominantLanguage else { return nil }
        return String(language.rawValue.prefix(2))
    }

    /// The same guess over a run of segments, joining only as many of them as the sample needs.
    static func dominantLanguage(of segments: [TranscriptSegment]) -> String? {
        var sample = ""
        var length = 0
        for segment in segments {
            if !sample.isEmpty { sample += " " }
            sample += segment.text
            length += segment.text.count + 1
            if length >= sampleLength { break }
        }
        return dominantLanguage(of: sample)
    }
}
