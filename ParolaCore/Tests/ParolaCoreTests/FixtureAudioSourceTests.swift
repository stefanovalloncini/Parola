import Foundation
import Testing
import AVFoundation
import Clocks
@testable import ParolaCore

@Suite("FixtureAudioSource smoke")
struct FixtureAudioSourceTests {

    @Test("start() opens a synthesised WAV without throwing")
    func startOpensWav() async throws {
        let url = try writeSilenceWav(duration: 0.05)
        defer { try? FileManager.default.removeItem(at: url) }

        let source = FixtureAudioSource.make(fixtureURL: url, clock: ImmediateClock())
        try await source.start()
        await source.cancel()
    }

    @Test("start() throws audioLoadFailed when the fixture is missing")
    func startThrowsWhenMissing() async {
        let missing = URL(fileURLWithPath: "/tmp/parola-fixture-\(UUID().uuidString).wav")
        let source = FixtureAudioSource.make(fixtureURL: missing, clock: ImmediateClock())

        do {
            try await source.start()
            Issue.record("expected start to throw")
        } catch is ParolaError {
            // ok
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    private func writeSilenceWav(duration: Double) throws -> URL {
        let sampleRate: Double = 16_000
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw FixtureWriteError.formatUnavailable
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw FixtureWriteError.bufferUnavailable
        }
        buffer.frameLength = frameCount

        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("parola-fixture-\(UUID().uuidString).wav")
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

    private enum FixtureWriteError: Error {
        case formatUnavailable
        case bufferUnavailable
    }
}
