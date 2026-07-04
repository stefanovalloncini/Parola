import Foundation
import Testing
import AVFoundation
@testable import ParolaCore

@Suite("FileAudioSource duration")
struct FileAudioSourceTests {

    @Test("synchronousDuration reports a known-length wav")
    func synchronousDurationKnownLength() throws {
        let url = try writeSilenceWav(seconds: 2.0, sampleRate: 16_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let seconds = FileAudioSource(url: url).synchronousDuration()
        #expect(seconds != nil)
        #expect(abs((seconds ?? 0) - 2.0) < 0.05)
    }

    @Test("synchronousDuration returns nil for a missing file")
    func synchronousDurationMissing() {
        let url = URL(fileURLWithPath: "/tmp/parola-missing-\(UUID().uuidString).wav")
        #expect(FileAudioSource(url: url).synchronousDuration() == nil)
    }

    private func writeSilenceWav(seconds: Double, sampleRate: Double) throws -> URL {
        let frameCount = AVAudioFrameCount(sampleRate * seconds)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw WavError.formatUnavailable
        }
        buffer.frameLength = frameCount

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-duration-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
        return url
    }

    private enum WavError: Error { case formatUnavailable }
}
