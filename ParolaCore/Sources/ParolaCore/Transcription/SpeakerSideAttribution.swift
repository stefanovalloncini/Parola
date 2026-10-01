import AVFoundation
import Foundation

/// The stereo take a meeting's two sides are told apart in, and the label your side takes.
public struct SpeakerSides: Sendable {
    public var stereo: URL
    public var meLabel: String

    public init(stereo: URL, meLabel: String) {
        self.stereo = stereo
        self.meLabel = meLabel
    }
}

/// Tells a meeting's segments apart by side: one clearly louder on your microphone (the right channel) than in
/// the Mac's audio (the left) is yours, and takes `meLabel`; every other segment keeps the speaker it had.
public enum SpeakerSideAttribution {
    /// How much louder your side has to be, in decibels.
    public static let dominance: Double = 6
    /// The level your side must reach, in dBFS, so room noise under a silent stretch never counts as you.
    public static let floor: Double = -45

    public static func label(segments: [TranscriptSegment], stereo: URL, meLabel: String) throws -> [TranscriptSegment] {
        guard !segments.isEmpty, let sides = try SideLevels(reading: stereo) else { return segments }
        return segments.map { segment in
            guard sides.micDominates(from: segment.start, to: segment.end) else { return segment }
            var labelled = segment
            labelled.speaker = meLabel
            labelled.words = segment.words?.map { word in
                var relabelled = word
                if relabelled.speaker != nil { relabelled.speaker = meLabel }
                return relabelled
            }
            return labelled
        }
    }
}

/// Each side's mean square level, a twentieth of a second at a time.
struct SideLevels {
    static let window: Double = 0.05

    let mac: [Double]
    let mic: [Double]

    /// Nil for a file with one channel, which has no sides to compare.
    init?(reading url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.channelCount >= 2 else { return nil }
        let windowFrames = max(1, Int(format.sampleRate * Self.window))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(windowFrames * 64)) else {
            throw ParolaError.audioLoadFailed(url, underlying: "could not build a read buffer")
        }
        var mac: [Double] = []
        var mic: [Double] = []
        var macSum = 0.0
        var micSum = 0.0
        var filled = 0
        while file.framePosition < file.length {
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: buffer.frameCapacity)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            for frame in 0..<frames {
                let left = Double(data[0][frame])
                let right = Double(data[1][frame])
                macSum += left * left
                micSum += right * right
                filled += 1
                guard filled == windowFrames else { continue }
                mac.append(macSum / Double(windowFrames))
                mic.append(micSum / Double(windowFrames))
                macSum = 0
                micSum = 0
                filled = 0
            }
        }
        if filled > 0 {
            mac.append(macSum / Double(filled))
            mic.append(micSum / Double(filled))
        }
        self.mac = mac
        self.mic = mic
    }

    func micDominates(from start: TimeInterval, to end: TimeInterval) -> Bool {
        let first = max(0, Int(start / Self.window))
        let last = min(mac.count, Int((end / Self.window).rounded(.up)))
        guard last > first else { return false }
        let micLevel = Self.decibels(mic[first..<last])
        return micLevel >= SpeakerSideAttribution.floor
            && micLevel - Self.decibels(mac[first..<last]) >= SpeakerSideAttribution.dominance
    }

    private static func decibels(_ meanSquares: ArraySlice<Double>) -> Double {
        let mean = meanSquares.reduce(0, +) / Double(meanSquares.count)
        return 10 * log10(max(mean, 1e-12))
    }
}
