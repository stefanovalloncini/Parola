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
        let seconds: [Double]
        let finalText: String

        init(emit: [String] = [], seconds: [Double] = [], finalText: String) {
            self.emit = emit
            self.seconds = seconds
            self.finalText = finalText
        }

        func load(model: String) async throws {}
        func unload() async {}
        func loadedModelName() async -> String? { "partials-stub" }

        func transcribe(
            url: URL,
            options: TranscriptionOptions,
            handlers: TranscribeHandlers
        ) async throws -> Transcript {
            for chunk in emit {
                handlers.onPartial?(chunk)
            }
            for second in seconds {
                handlers.onProgress?(second)
            }
            return Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: seconds.last ?? 1, text: finalText)],
                language: "en",
                modelName: "partials-stub",
                sourceURL: url,
                durationSeconds: seconds.last ?? 1
            )
        }
    }

    @Test("onPartial receives every emitted chunk in order")
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
            handlers: TranscribeHandlers(onPartial: { text in collected.append(text) })
        )

        #expect(collected.values == ["hello", "hello world", "hello world!"])
        #expect(transcript.segments.first?.text == "hello world!")
    }

    @Test("the no-handlers convenience still completes")
    func noHandlers() async throws {
        let stub = PartialEmittingTranscriber(emit: ["a", "ab"], finalText: "ab")
        let url = URL(fileURLWithPath: "/tmp/parola-partial-test-nohandler.wav")
        let transcript = try await stub.transcribe(
            url: url,
            options: TranscriptionOptions(model: "partials-stub")
        )
        #expect(transcript.segments.first?.text == "ab")
    }

    @Test("onProgress receives every reported second in order")
    func progressHandlerReceivesSeconds() async throws {
        let stub = PartialEmittingTranscriber(seconds: [1.0, 2.5, 5.0], finalText: "done")
        let collected = CollectedDoubles()
        let url = URL(fileURLWithPath: "/tmp/parola-progress-test.wav")

        _ = try await stub.transcribe(
            url: url,
            options: TranscriptionOptions(model: "partials-stub"),
            handlers: TranscribeHandlers(onProgress: { collected.append($0) })
        )

        #expect(collected.values == [1.0, 2.5, 5.0])
    }

    @Test("partials and progress deliver together from one run")
    func partialsAndProgressTogether() async throws {
        let stub = PartialEmittingTranscriber(emit: ["a", "ab"], seconds: [0.5], finalText: "ab")
        let partials = Collected()
        let seconds = CollectedDoubles()
        let url = URL(fileURLWithPath: "/tmp/parola-progress-default.wav")

        let transcript = try await stub.transcribe(
            url: url,
            options: TranscriptionOptions(model: "partials-stub"),
            handlers: TranscribeHandlers(
                onPartial: { partials.append($0) },
                onProgress: { seconds.append($0) }
            )
        )

        #expect(partials.values == ["a", "ab"])
        #expect(seconds.values == [0.5])
        #expect(transcript.segments.first?.text == "ab")
    }

    final class Collected: Sendable {
        private let storage = OSAllocatedUnfairLock(initialState: [String]())
        var values: [String] { storage.withLock { $0 } }
        func append(_ value: String) { storage.withLock { $0.append(value) } }
    }

    final class CollectedDoubles: Sendable {
        private let storage = OSAllocatedUnfairLock(initialState: [Double]())
        var values: [Double] { storage.withLock { $0 } }
        func append(_ value: Double) { storage.withLock { $0.append(value) } }
    }
}
