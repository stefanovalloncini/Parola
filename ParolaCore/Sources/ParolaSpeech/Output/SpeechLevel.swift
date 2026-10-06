import Foundation

/// A slow average of speech loudness and the cut toward the target; it never boosts (the voice gain does).
struct SpeechLevel: Equatable {
    static let targetDB = -20.0
    static let timeConstant = 3.0
    static let gainRangeDB: ClosedRange<Double> = -12...0

    private(set) var levelDB = targetDB

    var gainDB: Double {
        min(max(Self.targetDB - levelDB, Self.gainRangeDB.lowerBound), Self.gainRangeDB.upperBound)
    }

    var gain: Double { pow(10, gainDB / 20) }

    mutating func absorb(_ measure: SpeechMeasure) {
        guard measure.seconds > 0, let speechDB = measure.levelDB else { return }
        let weight = 1 - exp(-measure.seconds / Self.timeConstant)
        levelDB += weight * (speechDB - levelDB)
    }
}

/// The 10 ms blocks of a run of samples above the gate, and their mean power in dBFS.
struct SpeechMeasure: Equatable, Sendable {
    static let gateDB = -50.0
    static let blockSeconds = 0.01

    let seconds: Double
    let levelDB: Double?

    init(_ samples: [Float], sampleRate: Double) {
        let blockLength = max(1, Int(sampleRate * Self.blockSeconds))
        let gatePower = pow(10, Self.gateDB / 10)
        var speechPower = 0.0
        var speechFrames = 0
        var start = samples.startIndex
        while start < samples.endIndex {
            let end = min(start + blockLength, samples.endIndex)
            var sum = 0.0
            for index in start..<end {
                let sample = Double(samples[index])
                sum += sample * sample
            }
            let frames = end - start
            if sum / Double(frames) > gatePower {
                speechPower += sum
                speechFrames += frames
            }
            start = end
        }
        seconds = sampleRate > 0 ? Double(speechFrames) / sampleRate : 0
        levelDB = speechFrames > 0 ? 10 * log10(speechPower / Double(speechFrames)) : nil
    }
}
