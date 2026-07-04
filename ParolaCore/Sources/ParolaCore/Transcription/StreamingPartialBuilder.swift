import Foundation

/// Accumulates streamed transcription segments into one running partial string.
///
/// WhisperKit decodes audio windows concurrently, so segment-discovery callbacks can
/// arrive out of chronological order. Pieces are kept insert-sorted by `seek` (the absolute
/// sample offset), with arrival order breaking ties within a window, and a joined tail is
/// maintained incrementally so each callback costs O(new piece + tail), not O(total).
struct StreamingPartialBuilder {
    private struct Piece {
        let seek: Int
        let text: String
    }

    private var pieces: [Piece] = []
    private var tailStart = 0
    private var tailJoined = ""
    private let tailBudget: Int

    init(tailBudget: Int = 2000) {
        self.tailBudget = tailBudget
    }

    mutating func add(seek: Int, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let index = insertionIndex(forSeek: seek)
        pieces.insert(Piece(seek: seek, text: trimmed), at: index)
        if index < tailStart {
            tailStart += 1
        } else {
            rebuildTail()
        }
    }

    /// The full partial text so far, ordered by spoken position.
    var text: String {
        joined(from: 0)
    }

    /// The trailing `maxChars` of the partial, cut so it never starts mid-word.
    func tail(maxChars: Int = 2000) -> String {
        StreamingText.tail(of: maxChars <= tailBudget ? tailJoined : text, maxChars: maxChars)
    }

    private func insertionIndex(forSeek seek: Int) -> Int {
        var low = 0
        var high = pieces.count
        while low < high {
            let mid = (low + high) / 2
            if pieces[mid].seek <= seek {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private mutating func rebuildTail() {
        var start = tailStart
        var chars = joinedCount(from: start)
        while start < pieces.count - 1 {
            let head = pieces[start].text
            if head.isEmpty {
                start += 1
                continue
            }
            let remaining = chars - head.count - 1
            guard remaining >= tailBudget else { break }
            chars = remaining
            start += 1
        }
        tailStart = start
        tailJoined = joined(from: start)
    }

    private func joined(from start: Int) -> String {
        pieces[start...].lazy.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func joinedCount(from start: Int) -> Int {
        var total = 0
        for piece in pieces[start...] where !piece.text.isEmpty {
            total += (total == 0 ? 0 : 1) + piece.text.count
        }
        return total
    }
}
