import Foundation

/// Offers the loudest stretches of a mono waveform, loudest first, for callers that can only afford
/// to look at a few seconds of a long file. A tail worth half a window is offered too, so a file
/// that ends a few samples into its last window does not lose it. Windows never sit closer together
/// than `minimumSpacing`, which is a whole window unless the caller asks for less.
enum SpeechWindowFinder {
    static func loudestWindowOffsets(
        in samples: [Float],
        windowLength: Int,
        limit: Int,
        hopLength: Int? = nil,
        minimumSpacing: Int? = nil
    ) -> [Int] {
        guard windowLength > 0, limit > 0, !samples.isEmpty else { return [] }
        guard samples.count > windowLength else { return [0] }
        let hop = max(1, hopLength ?? windowLength / 2)
        let spacing = max(1, minimumSpacing ?? windowLength)

        var measured: [(offset: Int, energy: Float)] = []
        var offset = 0
        while offset + windowLength <= samples.count {
            measured.append((offset, rootMeanSquare(samples[offset..<(offset + windowLength)])))
            offset += hop
        }
        if offset < samples.count, samples.count - offset >= windowLength / 2 {
            measured.append((offset, rootMeanSquare(samples[offset...])))
        }
        measured.sort { $0.energy == $1.energy ? $0.offset < $1.offset : $0.energy > $1.energy }

        var picked: [Int] = []
        for candidate in measured where picked.allSatisfy({ abs($0 - candidate.offset) >= spacing }) {
            picked.append(candidate.offset)
            if picked.count == limit { break }
        }
        return picked
    }

    private static func rootMeanSquare(_ frame: ArraySlice<Float>) -> Float {
        guard !frame.isEmpty else { return 0 }
        let sumOfSquares = frame.reduce(Float(0)) { $0 + $1 * $1 }
        return (sumOfSquares / Float(frame.count)).squareRoot()
    }
}
