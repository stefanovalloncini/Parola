import Foundation

/// Locates the first stretch of sustained voice in a mono waveform by frame energy.
enum SpeechWindowFinder {
    static func firstSpeechOffset(
        in samples: [Float],
        sampleRate: Int,
        frameSeconds: Double = 0.1,
        energyThreshold: Float = 0.02,
        minimumSpeechSeconds: Double = 1.0
    ) -> Int? {
        let frameLength = Int(frameSeconds * Double(sampleRate))
        guard frameLength > 0, !samples.isEmpty else { return nil }
        let framesNeeded = max(1, Int((minimumSpeechSeconds / frameSeconds).rounded(.up)))

        var runStart: Int?
        var runLength = 0
        var frameStart = 0
        while frameStart < samples.count {
            let frameEnd = min(frameStart + frameLength, samples.count)
            if rootMeanSquare(samples[frameStart..<frameEnd]) >= energyThreshold {
                if runStart == nil { runStart = frameStart }
                runLength += 1
                if runLength >= framesNeeded { return runStart }
            } else {
                runStart = nil
                runLength = 0
            }
            frameStart += frameLength
        }
        return nil
    }

    private static func rootMeanSquare(_ frame: ArraySlice<Float>) -> Float {
        guard !frame.isEmpty else { return 0 }
        let sumOfSquares = frame.reduce(Float(0)) { $0 + $1 * $1 }
        return (sumOfSquares / Float(frame.count)).squareRoot()
    }
}
