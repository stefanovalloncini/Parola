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

    actor ProgressEmittingTranscriber: Transcriber {
        static let engineID = EngineID("progress-stub")
        static let capabilities = EngineCapabilities(
            supportedLanguages: .all,
            supportsTranslate: false,
            supportsInitialPrompt: false,
            supportsWordTimestamps: false,
            supportsDiarization: false
        )

        let seconds: [Double]

        init(seconds: [Double]) { self.seconds = seconds }

        func load(model: String) async throws {}
        func unload() async {}
        func loadedModelName() async -> String? { "progress-stub" }

        func transcribe(url: URL, options: TranscriptionOptions) async throws -> Transcript {
            try await transcribe(url: url, options: options, partialHandler: nil, progressHandler: nil)
        }

        func transcribe(
            url: URL,
            options: TranscriptionOptions,
            partialHandler: (@Sendable (String) -> Void)?,
            progressHandler: (@Sendable (Double) -> Void)?
        ) async throws -> Transcript {
            for second in seconds {
                progressHandler?(second)
            }
            return Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: seconds.last ?? 1, text: "done")],
                language: "en",
                modelName: "progress-stub",
                sourceURL: url,
                durationSeconds: seconds.last
            )
        }
    }

    @Test("progress handler receives every reported second in order")
    func progressHandlerReceivesSeconds() async throws {
        let stub = ProgressEmittingTranscriber(seconds: [1.0, 2.5, 5.0])
        let collected = CollectedDoubles()
        let url = URL(fileURLWithPath: "/tmp/parola-progress-test.wav")

        _ = try await stub.transcribe(
            url: url,
            options: TranscriptionOptions(model: "progress-stub"),
            partialHandler: nil,
            progressHandler: { collected.append($0) }
        )

        #expect(collected.values == [1.0, 2.5, 5.0])
    }

    @Test("a partial-only transcriber still streams partials through the default progress overload")
    func partialOnlyStubForwardsThroughProgressOverload() async throws {
        let stub = PartialEmittingTranscriber(emit: ["a", "ab"], finalText: "ab")
        let partials = Collected()
        let url = URL(fileURLWithPath: "/tmp/parola-progress-default.wav")

        let transcript = try await stub.transcribe(
            url: url,
            options: TranscriptionOptions(model: "partials-stub"),
            partialHandler: { partials.append($0) },
            progressHandler: { _ in }
        )

        #expect(partials.values == ["a", "ab"])
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
