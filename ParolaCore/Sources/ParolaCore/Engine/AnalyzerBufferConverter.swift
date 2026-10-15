import AVFoundation
import Foundation

/// Turns the capture's 16 kHz mono `[Float]` chunks into buffers in the format an analyzer asks for.
final class AnalyzerBufferConverter: @unchecked Sendable {
    // The capture delivers one chunk at a time, so the converter's state is never touched concurrently.
    static let captureFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!

    let target: AVAudioFormat
    private let converter: AVAudioConverter?

    init?(target: AVAudioFormat) {
        self.target = target
        if target == Self.captureFormat {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: Self.captureFormat, to: target) else { return nil }
            self.converter = converter
        }
    }

    func buffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let input = AVAudioPCMBuffer(pcmFormat: Self.captureFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            input.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        guard let converter else { return input }

        let ratio = target.sampleRate / Self.captureFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(samples.count) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var failure: NSError?
        let status = converter.convert(to: output, error: &failure) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, failure == nil, output.frameLength > 0 else { return nil }
        return output
    }
}
