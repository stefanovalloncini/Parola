import AVFoundation
import Foundation

/// Copies the loudest few stretches of a recording into one short scratch file. Language probing
/// runs on that instead of the head of the source, because a voice memo often opens with minutes
/// of room noise that would tell a recognizer nothing.
enum ProbeAudioExtractor {
    private static let measureSlices = 8
    private static let measureSliceSeconds = 0.5
    private static let copyChunkFrames: AVAudioFrameCount = 1 << 16

    static func extract(
        from source: URL,
        to destination: URL,
        windowSeconds: Double = ProbeWindowPlanner.windowSeconds,
        windowLimit: Int = ProbeWindowPlanner.windowLimit,
        candidateLimit: Int = ProbeWindowPlanner.candidateLimit
    ) throws -> [AudioProbeWindow] {
        let file = try AVAudioFile(forReading: source)
        let format = file.processingFormat
        guard format.sampleRate > 0, file.length > 0 else { return [] }
        let duration = Double(file.length) / format.sampleRate
        let candidates = ProbeWindowPlanner.candidates(
            duration: duration,
            windowSeconds: windowSeconds,
            limit: candidateLimit
        )
        guard !candidates.isEmpty else { return [] }

        let measured = try candidates.map {
            ProbeWindowEnergy(window: $0, energy: try energy(of: $0, in: file))
        }
        let windows = ProbeWindowPlanner.pick(from: measured, limit: windowLimit)
        guard !windows.isEmpty else { return [] }

        guard let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1) else {
            return []
        }
        let out = try AVAudioFile(
            forWriting: destination,
            settings: mono.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        for window in windows {
            try copy(window: window, from: file, to: out, as: mono)
        }
        return windows
    }

    /// Loudest slice, not the window's mean: a memo of a quiet room with one sentence in it should
    /// outrank a window of steady fan noise, and averaging buries the sentence.
    private static func energy(of window: AudioProbeWindow, in file: AVAudioFile) throws -> Double {
        let sampleRate = file.processingFormat.sampleRate
        let sliceFrames = AVAudioFrameCount(max(1, measureSliceSeconds * sampleRate))
        let sliceCount = max(1, min(measureSlices, Int(window.duration / measureSliceSeconds)))
        var loudest = 0.0
        for index in 0..<sliceCount {
            let centre = window.start + window.duration * (Double(index) + 0.5) / Double(sliceCount)
            let start = max(0, min(centre - measureSliceSeconds / 2, window.end - measureSliceSeconds))
            guard let buffer = try read(file: file, at: start, frames: sliceFrames) else { continue }
            let samples = Int(buffer.frameLength) * Int(buffer.format.channelCount)
            guard samples > 0 else { continue }
            loudest = max(loudest, (sumOfSquares(buffer) / Double(samples)).squareRoot())
        }
        return loudest
    }

    private static func read(
        file: AVAudioFile,
        at seconds: Double,
        frames: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer? {
        let position = AVAudioFramePosition(max(0, seconds) * file.processingFormat.sampleRate)
        guard position < file.length else { return nil }
        file.framePosition = position
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            return nil
        }
        try file.read(into: buffer, frameCount: frames)
        return buffer.frameLength > 0 ? buffer : nil
    }

    private static func copy(
        window: AudioProbeWindow,
        from file: AVAudioFile,
        to out: AVAudioFile,
        as mono: AVAudioFormat
    ) throws {
        let format = file.processingFormat
        file.framePosition = AVAudioFramePosition(window.start * format.sampleRate)
        var remaining = AVAudioFrameCount(window.duration * format.sampleRate)
        while remaining > 0 {
            let chunk = min(remaining, copyChunkFrames)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
            try file.read(into: buffer, frameCount: chunk)
            guard buffer.frameLength > 0 else { return }
            guard let downmixed = downmix(buffer, as: mono) else { return }
            try out.write(from: downmixed)
            remaining -= buffer.frameLength
        }
    }

    /// The probe file is mono so a multichannel source can't blow the scratch file up; channels are
    /// averaged rather than dropped, since a lapel rig can leave one side silent.
    private static func downmix(_ buffer: AVAudioPCMBuffer, as mono: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let input = buffer.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
              let output = out.floatChannelData?[0] else { return nil }
        out.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        for frame in 0..<Int(buffer.frameLength) {
            var sum: Float = 0
            for channel in 0..<channels { sum += input[channel][frame] }
            output[frame] = sum / Float(channels)
        }
        return out
    }

    private static func sumOfSquares(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let channels = buffer.floatChannelData else { return 0 }
        var total = 0.0
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = channels[channel]
            for frame in 0..<Int(buffer.frameLength) {
                let value = Double(samples[frame])
                total += value * value
            }
        }
        return total
    }
}
