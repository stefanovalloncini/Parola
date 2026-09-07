import Foundation
import Testing
import AVFoundation
@testable import ParolaCore

@Suite("Unreadable file error")
struct UnreadableFileErrorTests {
    private enum WavError: Error { case formatUnavailable }
    private enum TestOnlyError: Error { case boom }

    private func writeSilenceWav(seconds: Double, sampleRate: Double = 16_000) throws -> URL {
        let frameCount = AVAudioFrameCount(sampleRate * seconds)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw WavError.formatUnavailable
        }
        buffer.frameLength = frameCount
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-unreadable-source-\(UUID().uuidString).wav")
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

    private actor ThrowingTranscriber: Transcriber {
        static let engineID = EngineID.whisperKit
        static let capabilities = EngineCapabilities.whisperKitDefaults
        let error: any Error
        init(error: any Error) { self.error = error }
        func load(model: String) async throws {}
        func transcribe(url: URL, options: TranscriptionOptions, handlers: TranscribeHandlers) async throws -> Transcript {
            throw error
        }
        func unload() async {}
        func loadedModelName() async -> String? { nil }
    }

    private func makeSession(transcriber: ThrowingTranscriber, modelID: String = "openai_whisper-large-v3_turbo") async throws -> TranscriptionSession {
        let registry = EngineRegistry()
        await registry.register(engineID: .whisperKit, capabilities: .whisperKitDefaults) { _ in transcriber }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-unreadable-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ModelStore(modelsDirectory: dir)
        try store.seedInstalledModel(modelID)
        return TranscriptionSession(modelStore: store, registry: registry)
    }

    @Test("unreadableFileReason names an empty file")
    func reasonNamesEmptyFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString).m4a")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(TranscriptionSession.unreadableFileReason(at: url) == "The file is empty.")
    }

    @Test("unreadableFileReason stays quiet for a non-empty file")
    func reasonQuietForNonEmptyFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("garbage-\(UUID().uuidString).m4a")
        try Data("this is not audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(TranscriptionSession.unreadableFileReason(at: url) == nil)
    }

    @Test("an empty file's raw engine error becomes a plain sentence, not the OSStatus")
    func emptyFileGetsFriendlyMessage() async throws {
        let rawError = NSError(domain: "com.apple.coreaudio.avfaudio", code: 2_003_334_207)
        let transcriber = ThrowingTranscriber(error: rawError)
        let session = try await makeSession(transcriber: transcriber)
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString).m4a")
        try Data().write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        do {
            _ = try await session.transcribe(
                source: FileAudioSource(url: audioURL),
                options: TranscriptionOptions(model: "openai_whisper-large-v3_turbo")
            )
            Issue.record("expected a throw")
        } catch let error as ParolaError {
            #expect(error.description == "Parola couldn't read \(audioURL.lastPathComponent). The file is empty.")
            #expect(!error.description.contains("2003334207"))
        }
    }

    @Test("a non-empty unreadable file gets the plain sentence with no guessed reason")
    func garbageFileGetsPlainMessage() async throws {
        let rawError = NSError(domain: "com.apple.coreaudio.avfaudio", code: 1_954_115_647)
        let transcriber = ThrowingTranscriber(error: rawError)
        let session = try await makeSession(transcriber: transcriber)
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("garbage-\(UUID().uuidString).m4a")
        try Data("this is not audio".utf8).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        do {
            _ = try await session.transcribe(
                source: FileAudioSource(url: audioURL),
                options: TranscriptionOptions(model: "openai_whisper-large-v3_turbo")
            )
            Issue.record("expected a throw")
        } catch let error as ParolaError {
            #expect(error.description == "Parola couldn't read \(audioURL.lastPathComponent).")
        }
    }

    @Test("a real error on a genuinely readable file is left untouched")
    func readableFileRealErrorUntouched() async throws {
        let transcriber = ThrowingTranscriber(error: TestOnlyError.boom)
        let session = try await makeSession(transcriber: transcriber)
        let audioURL = try writeSilenceWav(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        do {
            _ = try await session.transcribe(
                source: FileAudioSource(url: audioURL),
                options: TranscriptionOptions(model: "openai_whisper-large-v3_turbo")
            )
            Issue.record("expected a throw")
        } catch is TestOnlyError {
            // expected: the session only rewrites the message for a genuinely unreadable file.
        } catch {
            Issue.record("expected the original error to survive untouched, got \(error)")
        }
    }
}
