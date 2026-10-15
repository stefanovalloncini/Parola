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
        let spans = runSpans(recognition.runs, totalCharacters: text.count)
        var pieces: [CaptionRecognition] = []
        for range in ranges {
            let piece = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            let low = text.distance(from: text.startIndex, to: range.lowerBound)
            let high = text.distance(from: text.startIndex, to: range.upperBound)
            let timed = spans.filter { $0.low < high && $0.high > low }
            let span = recognition.end - recognition.start
            let start = timed.compactMap(\.start).min() ?? recognition.start + span * Double(low) / Double(total)
            let end = timed.compactMap(\.end).max() ?? recognition.start + span * Double(high) / Double(total)
            pieces.append(CaptionRecognition(text: piece, start: start, end: end, isFinal: recognition.isFinal))
        }
        return pieces
    }

    private struct Span {
        var low: Int
        var high: Int
        var start: Double?
        var end: Double?
    }

    private static func runSpans(_ runs: [CaptionRecognition.Run], totalCharacters: Int) -> [Span] {
        var spans: [Span] = []
        var offset = 0
        for run in runs {
            let length = run.text.count
            spans.append(Span(low: offset, high: offset + length, start: run.start, end: run.end))
            offset += length
        }
        return offset == totalCharacters ? spans : []
    }
}
