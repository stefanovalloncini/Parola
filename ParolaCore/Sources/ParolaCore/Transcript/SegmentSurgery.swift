import Foundation

/// Pure split/merge transforms over a segment list. Returns nil when the request is a no-op,
/// so callers can skip the undo registration entirely.
public enum SegmentSurgery {

    /// The split list and the two ids it minted, so a caller remapping what the old id carried
    /// does not have to work them out again.
    public typealias Split = (segments: [TranscriptSegment], firstID: Int, secondID: Int)

    public static func split(segments: [TranscriptSegment], id: TranscriptSegment.ID, atWordIndex index: Int) -> Split? {
        guard let position = segments.firstIndex(where: { $0.id == id }) else { return nil }
        let segment = segments[position]
        guard let words = segment.words, (1..<words.count).contains(index) else { return nil }
        // Fresh ids instead of renumbering: stale ids elsewhere (playback cache, find matches) degrade to a lookup miss, not a wrong hit.
        let firstID = nextID(after: segments)
        let secondID = firstID + 1
        let boundary = words[index].start
        let first = TranscriptSegment(
            id: firstID,
            start: segment.start,
            end: boundary,
            text: joinWords(words[..<index].map(\.word)),
            speaker: segment.speaker,
            words: reindex(Array(words[..<index]), segmentID: firstID)
        )
        let second = TranscriptSegment(
            id: secondID,
            start: boundary,
            end: segment.end,
            text: joinWords(words[index...].map(\.word)),
            speaker: segment.speaker,
            words: reindex(Array(words[index...]), segmentID: secondID)
        )
        guard !first.text.isEmpty, !second.text.isEmpty else { return nil }
        var out = segments
        out.replaceSubrange(position...position, with: [first, second])
        return (out, firstID, secondID)
    }

    public static func split(segments: [TranscriptSegment], id: TranscriptSegment.ID, atFraction fraction: Double) -> Split? {
        guard let position = segments.firstIndex(where: { $0.id == id }) else { return nil }
        let segment = segments[position]
        if let words = segment.words, words.count >= 2 {
            return split(segments: segments, id: id, atWordIndex: wordBoundary(nearest: fraction, in: words, segment: segment))
        }
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let offset = splitOffset(in: text, nearestTo: fraction) else { return nil }
        let head = String(text.prefix(offset)).trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = String(text.dropFirst(offset)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty, !tail.isEmpty else { return nil }
        let boundary = segment.start + segment.duration * (Double(offset) / Double(text.count))
        let firstID = nextID(after: segments)
        let secondID = firstID + 1
        var out = segments
        out.replaceSubrange(position...position, with: [
            TranscriptSegment(id: firstID, start: segment.start, end: boundary, text: head, speaker: segment.speaker),
            TranscriptSegment(id: secondID, start: boundary, end: segment.end, text: tail, speaker: segment.speaker),
        ])
        return (out, firstID, secondID)
    }

    public static func mergeWithNext(segments: [TranscriptSegment], id: TranscriptSegment.ID) -> [TranscriptSegment]? {
        guard let position = segments.firstIndex(where: { $0.id == id }), position + 1 < segments.count else { return nil }
        let first = segments[position]
        let second = segments[position + 1]
        var merged = first
        merged.end = second.end
        merged.text = [first.text, second.text]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if let firstWords = first.words, let secondWords = second.words {
            merged.words = reindex(firstWords + secondWords, segmentID: first.id)
        } else {
            merged.words = nil
        }
        var out = segments
        out.replaceSubrange(position...(position + 1), with: [merged])
        return out
    }

    private static func nextID(after segments: [TranscriptSegment]) -> Int {
        (segments.map(\.id).max() ?? -1) + 1
    }

    private static func wordBoundary(nearest fraction: Double, in words: [WordTiming], segment: TranscriptSegment) -> Int {
        let target = segment.start + segment.duration * fraction
        return (1..<words.count).min { abs(words[$0].start - target) < abs(words[$1].start - target) } ?? 1
    }

    private static func splitOffset(in text: String, nearestTo fraction: Double) -> Int? {
        let target = fraction * Double(text.count)
        var best: Int?
        for (offset, character) in text.enumerated() where character.isWhitespace {
            if best == nil || abs(Double(offset) - target) < abs(Double(best!) - target) {
                best = offset
            }
        }
        return best
    }

    private static func joinWords(_ tokens: [String]) -> String {
        DiarizationService.joinWordTexts(tokens).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func reindex(_ words: [WordTiming], segmentID: Int) -> [WordTiming] {
        words.enumerated().map { index, word in
            var word = word
            word.id = "\(segmentID)-\(index)"
            return word
        }
    }
}
