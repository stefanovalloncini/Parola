import Accelerate
import AVFoundation
import Foundation

/// Finds a recording's loudest stretches for language probes: memos often open on minutes of room noise.
enum ProbeAudioExtractor {
    private static let measureSlices = 8
    private static let measureSliceSeconds = 0.5
    private static let copyChunkFrames: AVAudioFrameCount = 1 << 16

    static func measure(
        _ file: AVAudioFile,
        windowSeconds: Double = ProbeWindowPlanner.windowSeconds,
        candidateLimit: Int = ProbeWindowPlanner.candidateLimit
    ) throws -> [ProbeWindowEnergy] {
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0, file.length > 0 else { return [] }
        return try ProbeWindowPlanner.candidates(
            duration: Double(file.length) / sampleRate,
            windowSeconds: windowSeconds,
            limit: candidateLimit
        ).map { ProbeWindowEnergy(window: $0, energy: try energy(of: $0, in: file)) }
    }

    static func measure(
        samples: [Float],
        sampleRate: Double,
        windowSeconds: Double = ProbeWindowPlanner.windowSeconds,
        candidateLimit: Int = ProbeWindowPlanner.candidateLimit
    ) -> [ProbeWindowEnergy] {
        guard sampleRate > 0, !samples.isEmpty else { return [] }
        return ProbeWindowPlanner.candidates(
            duration: Double(samples.count) / sampleRate,
            windowSeconds: windowSeconds,
            limit: candidateLimit
        ).map { ProbeWindowEnergy(window: $0, energy: energy(of: $0, in: samples, sampleRate: sampleRate)) }
    }

    static func energy(of window: AudioProbeWindow, in file: AVAudioFile) throws -> Double {
        let frames = AVAudioFrameCount(max(1, measureSliceSeconds * file.processingFormat.sampleRate))
        var loudest = 0.0
        for start in sliceStarts(in: window) {
            guard let buffer = try read(file: file, at: start, frames: frames) else { continue }
            loudest = max(loudest, rootMeanSquare(buffer))
        }
        return loudest
    }

    static func energy(of window: AudioProbeWindow, in samples: [Float], sampleRate: Double) -> Double {
        let frames = max(1, Int(measureSliceSeconds * sampleRate))
        return samples.withUnsafeBufferPointer { all in
            var loudest = 0.0
            for start in sliceStarts(in: window) {
                let position = Int(max(0, start) * sampleRate)
                guard position < all.count else { continue }
                let slice = UnsafeBufferPointer(rebasing: all[position..<min(all.count, position + frames)])
                loudest = max(loudest, (Double(vDSP.sumOfSquares(slice)) / Double(slice.count)).squareRoot())
            }
            return loudest
        }
    }

    /// The loudest windows, each copied to its own mono file in `directory`, loudest first.
    static func extractWindows(
        from source: URL,
        into directory: URL,
        windowSeconds: Double = ProbeWindowPlanner.windowSeconds,
        windowLimit: Int = ProbeWindowPlanner.windowLimit,
        candidateLimit: Int = ProbeWindowPlanner.candidateLimit
    ) throws -> [URL] {
        let file = try AVAudioFile(forReading: source)
        let measured = try measure(file, windowSeconds: windowSeconds, candidateLimit: candidateLimit)
        let windows = ProbeWindowPlanner.ranked(from: measured, limit: windowLimit)
        guard !windows.isEmpty,
              let mono = AVAudioFormat(standardFormatWithSampleRate: file.processingFormat.sampleRate, channels: 1)
        else { return [] }
        return try windows.enumerated().map { index, window in
            let destination = directory.appendingPathComponent("window-\(index).caf")
            let out = try AVAudioFile(
                forWriting: destination,
                settings: mono.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try copy(window: window, from: file, to: out, as: mono)
            return destination
        }
    }

    /// Loudest slice, not the window's mean: a memo of a quiet room with one sentence in it should
    /// outrank a window of steady fan noise, and averaging buries the sentence.
    private static func sliceStarts(in window: AudioProbeWindow) -> [Double] {
        let count = max(1, min(measureSlices, Int(window.duration / measureSliceSeconds)))
        return (0..<count).map { index in
            let centre = window.start + window.duration * (Double(index) + 0.5) / Double(count)
            return max(0, min(centre - measureSliceSeconds / 2, window.end - measureSliceSeconds))
        }
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

    /// Channels are averaged rather than dropped, since a lapel rig can leave one side silent.
    private static func downmix(_ buffer: AVAudioPCMBuffer, as mono: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let input = buffer.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
              let output = out.floatChannelData?[0] else { return nil }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        out.frameLength = buffer.frameLength
        output.update(from: input[0], count: frames)
        guard channels > 1 else { return out }
        var mixed = UnsafeMutableBufferPointer(start: output, count: frames)
        for channel in 1..<channels {
            let sum = UnsafeBufferPointer(mixed)
            vDSP.add(UnsafeBufferPointer(start: input[channel], count: frames), sum, result: &mixed)
        }
        let sum = UnsafeBufferPointer(mixed)
        vDSP.multiply(1 / Float(channels), sum, result: &mixed)
        return out
    }

    private static func rootMeanSquare(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let channels = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0, channelCount > 0 else { return 0 }
        var total = 0.0
        for channel in 0..<channelCount {
            total += Double(vDSP.sumOfSquares(UnsafeBufferPointer(start: channels[channel], count: frames)))
        }
        return (total / Double(frames * channelCount)).squareRoot()
    }
}
