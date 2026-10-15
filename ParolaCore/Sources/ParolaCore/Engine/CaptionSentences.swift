import Foundation
import NaturalLanguage

enum CaptionSentences {
    /// A final that holds several sentences as one line each, timed from the analyzer's runs where it gave them.
    static func split(_ recognition: CaptionRecognition) -> [CaptionRecognition] {
        let text = recognition.text
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        let ranges = tokenizer.tokens(for: text.startIndex..<text.endIndex)
        guard ranges.count > 1 else { return [recognition] }

        let total = max(1, text.count)
        let bounds = ranges.map { (text.distance(from: text.startIndex, to: $0.lowerBound), text.distance(from: text.startIndex, to: $0.upperBound)) }
        let owned = runsBySentence(recognition.runs, text: text, bounds: bounds)
        var pieces: [CaptionRecognition] = []
        for (index, range) in ranges.enumerated() {
            let piece = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            let timed = owned[index]
            let span = recognition.end - recognition.start
            let start = timed.compactMap(\.start).min() ?? recognition.start + span * Double(bounds[index].0) / Double(total)
            let end = timed.compactMap(\.end).max() ?? recognition.start + span * Double(bounds[index].1) / Double(total)
            pieces.append(CaptionRecognition(text: piece, start: start, end: end, isFinal: recognition.isFinal))
        }
        return pieces
    }

    /// Each run belongs to the sentence holding its first non-space character: Speech puts the space before a word, and the tokenizer keeps it with the sentence before.
    private static func runsBySentence(
        _ runs: [CaptionRecognition.Run], text: String, bounds: [(Int, Int)]
    ) -> [[CaptionRecognition.Run]] {
        var owned = [[CaptionRecognition.Run]](repeating: [], count: bounds.count)
        guard runs.reduce(0, { $0 + $1.text.count }) == text.count else { return owned }
        var offset = 0
        for run in runs {
            defer { offset += run.text.count }
            guard let lead = run.text.firstIndex(where: { !$0.isWhitespace }) else { continue }
            let position = offset + run.text.distance(from: run.text.startIndex, to: lead)
            if let index = bounds.firstIndex(where: { position >= $0.0 && position < $0.1 }) { owned[index].append(run) }
        }
        return owned
    }
}
