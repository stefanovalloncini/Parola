import AVFoundation
import Foundation
import Testing
@testable import ParolaCore

@Suite("Transcription timing")
struct TranscriptionTimingTests {
    private enum WavError: Error { case formatUnavailable }

    private func writeSilenceWav(seconds: Double, sampleRate: Double = 16_000) throws -> URL {
        let frameCount = AVAudioFrameCount(sampleRate * seconds)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw WavError.formatUnavailable
        }
        buffer.frameLength = frameCount
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-timing-\(UUID().uuidString).wav")
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

    private func makeSession(delayMs: Int) async throws -> TranscriptionSession {
        let registry = EngineRegistry()
        let response = MockTranscriberResponse(
            segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "ok")],
            durationSeconds: 1,
            modelName: "nvidia_parakeet-tdt-0.6b-v2",
            delayMs: delayMs
        )
        await registry.register(engineID: .parakeet, capabilities: .parakeetDefaults) { _ in
            MockTranscriber.make(response: response, clock: ContinuousClock())
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-timing-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ModelStore(modelsDirectory: dir)
        try store.seedInstalledModel("nvidia_parakeet-tdt-0.6b-v2")
        return TranscriptionSession(modelStore: store, registry: registry)
    }

    @Test("a file run comes back stamped with the wall time the engine took")
    func runIsTimed() async throws {
        let session = try await makeSession(delayMs: 150)
        let audioURL = try writeSilenceWav(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let transcript = try await session.transcribe(
            source: FileAudioSource(url: audioURL),
            options: TranscriptionOptions(model: "nvidia_parakeet-tdt-0.6b-v2")
        )
        await session.unloadModel()

        let seconds = try #require(transcript.transcriptionSeconds)
        #expect(seconds >= 0.15)
        #expect(seconds < 60)
    }

    @Test("a transcript that never ran through a file carries no timing")
    func untimedByDefault() {
        let transcript = Transcript(segments: [], language: "en", modelName: "stub")
        #expect(transcript.transcriptionSeconds == nil)
    }

    @Test("timing round-trips through Codable and an older transcript decodes without it")
    func timingRoundTrips() throws {
        var transcript = Transcript(segments: [], language: "en", modelName: "stub")
        transcript.transcriptionSeconds = 37.5
        let data = try JSONEncoder().encode(transcript)
        #expect(try JSONDecoder().decode(Transcript.self, from: data).transcriptionSeconds == 37.5)

        let older = Data(#"{"schemaVersion":1,"segments":[],"language":"en","modelName":"stub"}"#.utf8)
        #expect(try JSONDecoder().decode(Transcript.self, from: older).transcriptionSeconds == nil)
    }

    @Test("an untimed transcript leaves the key out of its JSON")
    func nilTimingIsNotEncoded() throws {
        let transcript = Transcript(segments: [], language: "en", modelName: "stub")
        let json = String(decoding: try JSONEncoder().encode(transcript), as: UTF8.self)
        #expect(!json.contains("transcriptionSeconds"))
    }

    @Test("word count reads the spoken text, not the segment count")
    func wordCountCountsWords() {
        let transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: "  due parole  "),
                TranscriptSegment(id: 1, start: 1, end: 2, text: "e\nancora tre"),
                TranscriptSegment(id: 2, start: 2, end: 3, text: "   "),
            ],
            language: "it",
            modelName: "stub"
        )
        #expect(transcript.wordCount == 5)
        #expect(Transcript(segments: [], language: "en", modelName: "stub").wordCount == 0)
    }
}
