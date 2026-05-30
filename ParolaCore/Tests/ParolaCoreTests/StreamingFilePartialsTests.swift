import Foundation
import os
import Testing
@testable import ParolaCore

@Suite("Streaming file transcription partials")
struct StreamingFilePartialsTests {
    actor PartialEmittingTranscriber: Transcriber {
        static let engineID = EngineID("partials-stub")
        static let capabilities = EngineCapabilities(
            supportedLanguages: .all,
            supportsTranslate: false,
            supportsInitialPrompt: false,
            supportsWordTimestamps: false,
            supportsDiarization: false
        )

        let emit: [String]
        let finalText: String

        init(emit: [String], finalText: String) {
            self.emit = emit
            self.finalText = finalText
        }

        func load(model: String) async throws {}
        func unload() async {}
        func loadedModelName() async -> String? { "partials-stub" }

        func transcribe(url: URL, options: TranscriptionOptions) async throws -> Transcript {
            try await transcribe(url: url, options: options, partialHandler: nil)
        }

        func transcribe(
            url: URL,
            options: TranscriptionOptions,
            partialHandler: (@Sendable (String) -> Void)?
        ) async throws -> Transcript {
            for chunk in emit {
                partialHandler?(chunk)
            }
            return Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: finalText)],
                language: "en",
                modelName: "partials-stub",
                sourceURL: url,
                durationSeconds: 1
            )
        }
    }

    @Test("partial handler receives every emitted chunk in order")
    func partialHandlerReceivesChunks() async throws {
        let stub = PartialEmittingTranscriber(
            emit: ["hello", "hello world", "hello world!"],
            finalText: "hello world!"
        )
        let collected = Collected()
        let url = URL(fileURLWithPath: "/tmp/parola-partial-test.wav")

        let transcript = try await stub.transcribe(
            url: url,
            options: TranscriptionOptions(model: "partials-stub"),
            partialHandler: { text in collected.append(text) }
        )

        #expect(collected.values == ["hello", "hello world", "hello world!"])
        #expect(transcript.segments.first?.text == "hello world!")
    }

    @Test("transcribe without a partial handler still completes")
    func noPartialHandler() async throws {
        let stub = PartialEmittingTranscriber(emit: ["a", "ab"], finalText: "ab")
        let url = URL(fileURLWithPath: "/tmp/parola-partial-test-nohandler.wav")
        let transcript = try await stub.transcribe(
            url: url,
            options: TranscriptionOptions(model: "partials-stub")
        )
        #expect(transcript.segments.first?.text == "ab")
    }

    final class Collected: Sendable {
        private let storage = OSAllocatedUnfairLock(initialState: [String]())
        var values: [String] { storage.withLock { $0 } }
        func append(_ value: String) { storage.withLock { $0.append(value) } }
    }
}
