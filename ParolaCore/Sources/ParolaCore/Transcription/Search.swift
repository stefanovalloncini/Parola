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
        return segments.flatMap { segment in
            Self.matchRanges(of: query, in: segment.text, caseSensitive: caseSensitive).map {
                TranscriptMatch(segmentID: segment.id, range: $0.location..<NSMaxRange($0))
            }
        }
    }

    /// Whether any of `segments` holds a match `findMatches` would return, stopping at the first segment that does.
    static func containsMatch(_ query: String, caseSensitive: Bool = false, in segments: [TranscriptSegment]) -> Bool {
        guard !query.isEmpty else { return false }
        return segments.contains { !matchRanges(of: query, in: $0.text, caseSensitive: caseSensitive).isEmpty }
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

    /// Returns a new transcript with every match `findMatches` returns replaced.
    func replacingAll(_ query: String, with replacement: String, caseSensitive: Bool = false) -> Transcript {
        guard !query.isEmpty else { return self }
        var copy = self
        for i in copy.segments.indices {
            let ranges = Self.matchRanges(of: query, in: copy.segments[i].text, caseSensitive: caseSensitive)
            guard !ranges.isEmpty else { continue }
            let rewritten = NSMutableString(string: copy.segments[i].text)
            for range in ranges.reversed() { rewritten.replaceCharacters(in: range, with: replacement) }
            let newText = rewritten as String
            guard newText != copy.segments[i].text else { continue }
            copy.segments[i].text = newText
            copy.segments[i].words = nil
        }
        return copy
    }

    /// NSString's hits as UTF-16 ranges, minus any that cut a character (👍🏽's modifier): Replace can't apply half of one.
    private static func matchRanges(of query: String, in string: String, caseSensitive: Bool) -> [NSRange] {
        let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        let text = string as NSString
        let length = text.length
        var out: [NSRange] = []
        var location = 0
        while location < length {
            let found = text.range(of: query, options: options, range: NSRange(location: location, length: length - location))
            guard found.location != NSNotFound else { break }
            guard isCharacterBoundary(found.location, in: string), isCharacterBoundary(NSMaxRange(found), in: string) else {
                location = found.location + 1
                continue
            }
            out.append(found)
            location = max(NSMaxRange(found), location + 1)
        }
        return out
    }

    private static func isCharacterBoundary(_ utf16Offset: Int, in text: String) -> Bool {
        let utf16 = text.utf16
        guard let index = utf16.index(utf16.startIndex, offsetBy: utf16Offset, limitedBy: utf16.endIndex) else { return false }
        return String.Index(index, within: text) != nil
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
