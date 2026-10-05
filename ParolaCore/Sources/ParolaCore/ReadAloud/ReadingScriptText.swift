import Foundation
import NaturalLanguage

/// The whole script in one string, so the sentence tokenizer is set up once, with each piece's source and each run's start.
struct AnchoredText {
    struct Span {
        let anchor: ReadingAnchor
        let start: Int
        let end: Int
        let sourceStart: Int
    }

    struct Run {
        let start: Int
        let pauseBefore: Double
    }

    private(set) var text = ""
    private(set) var spans: [Span] = []
    private(set) var runs: [Run] = []
    private var length = 0

    mutating func startRun(pauseBefore: Double) {
        if !runs.isEmpty { appendSeparator("\n") }
        runs.append(Run(start: length, pauseBefore: pauseBefore))
    }

    mutating func append(_ piece: Substring, from anchor: ReadingAnchor, at sourceStart: Int) {
        let count = piece.utf16.count
        guard count > 0 else { return }
        spans.append(Span(anchor: anchor, start: length, end: length + count, sourceStart: sourceStart))
        text += piece
        length += count
    }

    mutating func appendSeparator(_ separator: String) {
        text += separator
        length += separator.utf16.count
    }

    /// `cursor` only moves forward, so callers must ask for ranges in ascending order.
    func anchors(for range: NSRange, cursor: inout Int) -> [ReadingUnit.Anchored] {
        let lower = range.location
        let upper = NSMaxRange(range)
        while cursor < spans.count, spans[cursor].end <= lower { cursor += 1 }
        var anchors: [ReadingUnit.Anchored] = []
        var index = cursor
        while index < spans.count, spans[index].start < upper {
            let span = spans[index]
            let from = span.sourceStart + max(lower, span.start) - span.start
            let to = span.sourceStart + min(upper, span.end) - span.start
            anchors.merge(ReadingUnit.Anchored(anchor: span.anchor, range: NSRange(location: from, length: to - from)))
            index += 1
        }
        return anchors
    }
}

extension [ReadingUnit.Anchored] {
    mutating func merge(_ other: ReadingUnit.Anchored) {
        guard let index = firstIndex(where: { $0.anchor == other.anchor }) else {
            append(other)
            return
        }
        let existing = self[index].range
        let lower = Swift.min(existing.location, other.range.location)
        let upper = Swift.max(NSMaxRange(existing), NSMaxRange(other.range))
        self[index] = ReadingUnit.Anchored(anchor: other.anchor, range: NSRange(location: lower, length: upper - lower))
    }

    mutating func merge(_ others: [ReadingUnit.Anchored]) {
        for other in others { merge(other) }
    }
}

struct DraftUnit {
    let text: String
    var anchors: [ReadingUnit.Anchored]
    var pauseAfter: Double
    let isSpoken: Bool
}

struct SentenceSplitter {
    private static let clauseMarks: Set<Character> = [",", ";", ":"]
    private static let fullWidthClauseMarks: Set<Character> = ["，", "；", "：", "、"]

    private let language: NLLanguage?
    private let maxLength: Int

    init(language: String?, maxLength: Int) {
        self.language = language.flatMap { $0.isEmpty ? nil : NLLanguage(rawValue: $0) }
        self.maxLength = maxLength
    }

    func drafts(of script: AnchoredText) -> [DraftUnit] {
        let text = script.text
        let runStarts = script.runs.map { String.Index(utf16Offset: $0.start, in: text) }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        if let language { tokenizer.setLanguage(language) }
        var drafts: [DraftUnit] = []
        var spanCursor = 0
        var run = 0
        var pendingPause = 0.0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { sentence, _ in
            var lower = sentence.lowerBound
            while lower < sentence.upperBound {
                while run + 1 < runStarts.count, runStarts[run + 1] <= lower {
                    run += 1
                    pendingPause = max(pendingPause, script.runs[run].pauseBefore)
                }
                let upper = run + 1 < runStarts.count ? min(sentence.upperBound, runStarts[run + 1]) : sentence.upperBound
                for piece in pieces(of: lower..<upper, in: text) {
                    if let last = drafts.indices.last {
                        drafts[last].pauseAfter = max(drafts[last].pauseAfter, pendingPause)
                    }
                    pendingPause = 0
                    let spoken = text[piece]
                    drafts.append(DraftUnit(
                        text: String(spoken),
                        anchors: script.anchors(for: NSRange(piece, in: text), cursor: &spanCursor),
                        pauseAfter: 0,
                        isSpoken: spoken.contains { $0.isLetter || $0.isNumber }
                    ))
                }
                lower = upper
            }
            return true
        }
        return drafts
    }

    static func trimmed(_ range: Range<String.Index>, in text: String) -> Range<String.Index>? {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, text[lower].isWhitespace { lower = text.index(after: lower) }
        while lower < upper {
            let before = text.index(before: upper)
            guard text[before].isWhitespace else { break }
            upper = before
        }
        return lower < upper ? lower..<upper : nil
    }

    private func pieces(of sentence: Range<String.Index>, in text: String) -> [Range<String.Index>] {
        guard let sentence = Self.trimmed(sentence, in: text) else { return [] }
        var pieces: [Range<String.Index>] = []
        var start = sentence.lowerBound
        while let limit = text.index(start, offsetBy: maxLength, limitedBy: sentence.upperBound),
              limit < sentence.upperBound,
              let cut = Self.cut(in: start..<sentence.upperBound, limit: limit, text: text) {
            if let piece = Self.trimmed(start..<cut, in: text) { pieces.append(piece) }
            start = cut
            while start < sentence.upperBound, text[start].isWhitespace { start = text.index(after: start) }
        }
        if let rest = Self.trimmed(start..<sentence.upperBound, in: text) { pieces.append(rest) }
        return pieces
    }

    /// After the last clause mark within `limit`, else the last space, else the first space past it: never inside a word.
    private static func cut(in range: Range<String.Index>, limit: String.Index, text: String) -> String.Index? {
        var clauseCut: String.Index?
        var spaceCut: String.Index?
        var index = range.lowerBound
        while index <= limit {
            let character = text[index]
            let next = text.index(after: index)
            if character.isWhitespace {
                spaceCut = index
            } else if index < limit {
                if fullWidthClauseMarks.contains(character) {
                    clauseCut = next
                } else if clauseMarks.contains(character), next < range.upperBound, text[next].isWhitespace {
                    clauseCut = next
                }
            }
            index = next
        }
        if let cut = clauseCut ?? spaceCut { return cut }
        return text[limit..<range.upperBound].firstIndex(where: \.isWhitespace)
    }
}
