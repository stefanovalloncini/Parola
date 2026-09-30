import Foundation
import Testing
import AVFoundation
import Clocks
@testable import ParolaCore

@Suite("FixtureAudioSource smoke")
struct FixtureAudioSourceTests {

    @Test("start() opens a synthesised WAV without throwing")
    func startOpensWav() async throws {
        let url = try writeWav(duration: 0.05)
        defer { try? FileManager.default.removeItem(at: url) }

        let source = FixtureAudioSource.make(fixtureURL: url, clock: ImmediateClock())
        try await source.start()
        await source.cancel()
    }

    @Test("a playing fixture keeps the level meter current, and cancelling rests it")
    func fixtureWritesTheLevelMeter() async throws {
        let url = try writeWav(duration: 0.3, amplitude: 0.3)
        defer { try? FileManager.default.removeItem(at: url) }

        let source = FixtureAudioSource.make(fixtureURL: url, clock: ContinuousClock())
        try await source.start()
        let deadline = ContinuousClock.now + .seconds(5)
        while source.levelMeter.lastSound == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(source.levelMeter.lastSound != nil)

        await source.cancel()
        #expect(source.levelMeter.level == 0)
    }

    @Test("pausing a fixture stops its level meter, and resuming starts it again")
    func setPausedStopsAndResumesPacing() async throws {
        let url = try writeWav(duration: 2.0, amplitude: 0.3)
        defer { try? FileManager.default.removeItem(at: url) }

        let source = FixtureAudioSource.make(fixtureURL: url, clock: ContinuousClock())
        try await source.start()
        let firstDeadline = ContinuousClock.now + .seconds(5)
        while source.levelMeter.lastSound == nil, ContinuousClock.now < firstDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(source.levelMeter.lastSound != nil)

        await source.setPaused(true)
        source.levelMeter.reset()
        try await Task.sleep(for: .milliseconds(200))
        #expect(source.levelMeter.lastSound == nil, "a paused fixture should not feed the meter")

        await source.setPaused(false)
        let resumedDeadline = ContinuousClock.now + .seconds(5)
        while source.levelMeter.lastSound == nil, ContinuousClock.now < resumedDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(source.levelMeter.lastSound != nil, "resuming should feed the meter again")

        await source.cancel()
    }

    @Test("a started fixture names itself as the file in flight, through the protocol and on the concrete type")
    func fixtureIsTheFileInFlight() async throws {
        let url = try writeWav(duration: 0.05)
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = FixtureAudioSource.make(fixtureURL: url, clock: ImmediateClock())
        let source: any LiveAudioSource = fixture
        #expect(await source.inFlightURL() == nil)

        try await fixture.start()
        #expect(await source.inFlightURL() == url)
        #expect(await fixture.inFlightURL() == url)

        await fixture.cancel()
        #expect(await source.inFlightURL() == nil)
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

    private func writeWav(duration: Double, amplitude: Float = 0) throws -> URL {
        let sampleRate: Double = 16_000
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw FixtureWriteError.formatUnavailable
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw FixtureWriteError.bufferUnavailable
        }
        buffer.frameLength = frameCount
        if amplitude > 0, let samples = buffer.floatChannelData?[0] {
            for index in 0..<Int(frameCount) { samples[index] = index.isMultiple(of: 2) ? amplitude : -amplitude }
        }

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
