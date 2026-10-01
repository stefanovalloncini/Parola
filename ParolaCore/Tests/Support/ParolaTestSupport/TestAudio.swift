import AVFoundation
import Foundation

/// Short WAV files for audio tests: 48 kHz Float32 unless asked otherwise, a sine on each channel.
public enum TestAudio {
    public static let sampleRate: Double = 48_000

    public struct Samples: Sendable {
        public let channels: [[Float]]
        public let sampleRate: Double

        public var frameCount: Int { channels.first?.count ?? 0 }
        public var seconds: Double { Double(frameCount) / sampleRate }

        /// The root-mean-square level of one channel between two times.
        public func rms(channel: Int, from start: Double, to end: Double) -> Float {
            let samples = channels[channel]
            let first = max(0, min(samples.count, Int(start * sampleRate)))
            let last = max(first, min(samples.count, Int(end * sampleRate)))
            guard last > first else { return 0 }
            let squares = samples[first..<last].reduce(Float(0)) { $0 + $1 * $1 }
            return (squares / Float(last - first)).squareRoot()
        }
    }

    public static func sine(seconds: Double, hz: Double, amplitude: Float, sampleRate: Double = sampleRate) -> [Float] {
        let count = Int(seconds * sampleRate)
        return (0..<count).map { amplitude * Float(sin(2 * Double.pi * hz * Double($0) / sampleRate)) }
    }

    @discardableResult
    public static func tone(seconds: Double, hz: Double, amplitude: Float, at url: URL, sampleRate: Double = sampleRate) throws -> URL {
        try write(channels: [sine(seconds: seconds, hz: hz, amplitude: amplitude, sampleRate: sampleRate)], sampleRate: sampleRate, to: url)
    }

    /// Two sines, left and right, each at its own amplitude, in a temporary file unless `url` names one.
    public static func stereo(leftAmplitude: Float, rightAmplitude: Float, seconds: Double, at url: URL? = nil) throws -> URL {
        let target = url ?? FileManager.default.temporaryDirectory.appendingPathComponent("parola-test-stereo-\(UUID().uuidString).wav")
        return try write(
            channels: [
                sine(seconds: seconds, hz: 440, amplitude: leftAmplitude),
                sine(seconds: seconds, hz: 220, amplitude: rightAmplitude),
            ],
            to: target
        )
    }

    /// One array per channel, all the same length.
    @discardableResult
    public static func write(channels: [[Float]], sampleRate: Double = sampleRate, to url: URL) throws -> URL {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels.count), interleaved: false
        ) else { throw CocoaError(.fileWriteUnknown) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = channels.first?.count ?? 0
        guard frames > 0 else { return url }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let data = buffer.floatChannelData else { throw CocoaError(.fileWriteUnknown) }
        buffer.frameLength = AVAudioFrameCount(frames)
        for (index, samples) in channels.enumerated() {
            samples.withUnsafeBufferPointer { data[index].update(from: $0.baseAddress!, count: frames) }
        }
        try file.write(from: buffer)
        return url
    }

    public static func read(_ url: URL) throws -> Samples {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        let count = Int(format.channelCount)
        guard frames > 0 else { return Samples(channels: Array(repeating: [], count: count), sampleRate: format.sampleRate) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { throw CocoaError(.fileReadUnknown) }
        try file.read(into: buffer, frameCount: frames)
        guard let data = buffer.floatChannelData else { throw CocoaError(.fileReadUnknown) }
        let length = Int(buffer.frameLength)
        let channels = (0..<count).map { Array(UnsafeBufferPointer(start: data[$0], count: length)) }
        return Samples(channels: channels, sampleRate: format.sampleRate)
    }
}
