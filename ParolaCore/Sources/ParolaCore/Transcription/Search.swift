import Foundation

/// One occurrence of a query inside a transcript segment.
public struct TranscriptMatch: Hashable, Sendable, Identifiable {
    public var id: String { "\(segmentID):\(range.lowerBound)-\(range.upperBound)" }

    /// `TranscriptSegment.id` of the segment containing the match.
    public var segmentID: Int

    /// UTF-16 offsets into the segment's `text`.
    public var range: Range<Int>

    public init(segmentID: Int, range: Range<Int>) {
        self.segmentID = segmentID
        self.range = range
    }
}

public extension Transcript {
    /// Returns every occurrence of `query` in any segment. Empty query → empty result.
    func findMatches(_ query: String, caseSensitive: Bool = false) -> [TranscriptMatch] {
        guard !query.isEmpty else { return [] }
        var out: [TranscriptMatch] = []
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        for segment in segments {
            var searchStart = segment.text.startIndex
            while searchStart < segment.text.endIndex,
                  let r = segment.text.range(of: query, options: options, range: searchStart..<segment.text.endIndex) {
                let lo = segment.text.utf16.distance(from: segment.text.startIndex, to: r.lowerBound)
                let hi = segment.text.utf16.distance(from: segment.text.startIndex, to: r.upperBound)
                out.append(TranscriptMatch(segmentID: segment.id, range: lo..<hi))
                searchStart = r.upperBound
            }
        }
        return out
    }

    /// Returns a new transcript with `match` replaced by `replacement`.
    func applying(replacement: String, to match: TranscriptMatch) -> Transcript {
        var copy = self
        guard let idx = copy.segments.firstIndex(where: { $0.id == match.segmentID }) else { return self }
        let newText = Self.applying(replacement: replacement, to: match.range, in: copy.segments[idx].text)
        guard newText != copy.segments[idx].text else { return copy }
        copy.segments[idx].text = newText
        copy.segments[idx].words = nil
        return copy
    }

    /// Returns a new transcript with every occurrence of `query` replaced.
    func replacingAll(_ query: String, with replacement: String, caseSensitive: Bool = false) -> Transcript {
        guard !query.isEmpty else { return self }
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var copy = self
        for i in copy.segments.indices {
            let newText = copy.segments[i].text
                .replacingOccurrences(of: query, with: replacement, options: options)
            guard newText != copy.segments[i].text else { continue }
            copy.segments[i].text = newText
            copy.segments[i].words = nil
        }
        return copy
    }

    private static func applying(replacement: String, to range: Range<Int>, in text: String) -> String {
        let utf16 = text.utf16
        guard
            range.lowerBound >= 0,
            let lo = utf16.index(utf16.startIndex, offsetBy: range.lowerBound, limitedBy: utf16.endIndex),
            let hi = utf16.index(utf16.startIndex, offsetBy: range.upperBound, limitedBy: utf16.endIndex),
            let stringLo = String.Index(lo, within: text),
            let stringHi = String.Index(hi, within: text)
        else { return text }
        return text.replacingCharacters(in: stringLo..<stringHi, with: replacement)
    }
}
