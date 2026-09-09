import Foundation
import Testing
import AVFoundation
import Clocks
@testable import ParolaCore

@Suite("TranscriptionSession duration override")
struct TranscriptionSessionDurationTests {
    private enum WavError: Error { case formatUnavailable }

    private func writeSilenceWav(seconds: Double, sampleRate: Double = 16_000) throws -> URL {
        let frameCount = AVAudioFrameCount(sampleRate * seconds)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw WavError.formatUnavailable
        }
        buffer.frameLength = frameCount
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-duration-session-\(UUID().uuidString).wav")
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

    private static func modelID(for engineID: EngineID) -> String {
        switch engineID {
        case .whisperKit: return "openai_whisper-large-v3_turbo"
        case .parakeet: return "nvidia_parakeet-tdt-0.6b-v2"
        default: return "apple-speech-analyzer"
        }
    }

    private static func capabilities(for engineID: EngineID) -> EngineCapabilities {
        switch engineID {
        case .whisperKit: return .whisperKitDefaults
        case .parakeet: return .parakeetDefaults
        default: return .appleSpeechDefaults
        }
    }

    private func makeSession(engineID: EngineID, engineReportedDuration: Double) async throws -> TranscriptionSession {
        let registry = EngineRegistry()
        let response = MockTranscriberResponse(
            segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "ok")],
            durationSeconds: engineReportedDuration,
            modelName: Self.modelID(for: engineID)
        )
        await registry.register(engineID: engineID, capabilities: Self.capabilities(for: engineID)) { _ in
            MockTranscriber.make(response: response, clock: ImmediateClock())
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-duration-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ModelStore(modelsDirectory: dir)
        if engineID != .appleSpeech {
            try store.seedInstalledModel(Self.modelID(for: engineID))
        }
        return TranscriptionSession(modelStore: store, registry: registry)
    }

    @Test(
        "the source file's real duration wins over whatever the engine reported",
        arguments: [EngineID.whisperKit, EngineID.parakeet, EngineID.appleSpeech]
    )
    func durationComesFromTheSourceFile(engineID: EngineID) async throws {
        // Every engine misreports on purpose here — 999s stands in for Parakeet's "no duration at
        // all" (materialise still needs a value) and for Whisper/Apple Speech disagreeing with the file.
        let session = try await makeSession(engineID: engineID, engineReportedDuration: 999)
        let audioURL = try writeSilenceWav(seconds: 2.0)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let transcript = try await session.transcribe(
            source: FileAudioSource(url: audioURL),
            options: TranscriptionOptions(model: Self.modelID(for: engineID))
        )
        await session.unloadModel()

        let duration = try #require(transcript.durationSeconds)
        #expect(abs(duration - 2.0) < 0.05)
    }

    @Test("falls back to the transcript's own segments when neither probe can read the file")
    func durationFallsBackToSegmentsWhenUnprobeable() async throws {
        let session = try await makeSession(engineID: .parakeet, engineReportedDuration: 999)
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-duration-garbage-\(UUID().uuidString).bin")
        try Data("not an audio file".utf8).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let transcript = try await session.transcribe(
            source: FileAudioSource(url: audioURL),
            options: TranscriptionOptions(model: Self.modelID(for: .parakeet))
        )
        await session.unloadModel()

        #expect(transcript.durationSeconds == 1.0)
    }
}
