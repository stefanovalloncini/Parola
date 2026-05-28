import Foundation

/// Accumulates streamed transcription segments into one running partial string.
///
/// WhisperKit decodes audio windows concurrently, so segment-discovery callbacks can
/// arrive out of chronological order. Keying by `seek` (the absolute sample offset) keeps
/// the running text in spoken order; the arrival index breaks ties within a single window.
struct StreamingPartialBuilder {
    private struct Piece {
        let seek: Int
        let arrival: Int
        let text: String
    }

    private var pieces: [Piece] = []
    private var nextArrival = 0

    mutating func add(seek: Int, text: String) {
        pieces.append(Piece(seek: seek, arrival: nextArrival, text: text.trimmingCharacters(in: .whitespaces)))
        nextArrival += 1
    }

    /// The full partial text so far, ordered by spoken position.
    var text: String {
        pieces
            .sorted { ($0.seek, $0.arrival) < ($1.seek, $1.arrival) }
            .map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
