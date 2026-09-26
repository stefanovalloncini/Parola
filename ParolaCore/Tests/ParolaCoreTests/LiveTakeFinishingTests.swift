import Foundation
import Testing
@preconcurrency import WhisperKit
@testable import ParolaCore

@Suite("A live take is finished like a file run", .serialized)
struct LiveTakeFinishingTests {
    private actor MappedTranscriber: Transcriber {
        static let engineID = EngineID.whisperKit
        static let capabilities = EngineCapabilities.whisperKitDefaults

        private let raw: [TranscriptionSegment]
        private var loaded: String?

        init(raw: [TranscriptionSegment]) {
            self.raw = raw
        }

        func load(model: String) async throws { loaded = model }
        func unload() async { loaded = nil }
        func loadedModelName() async -> String? { loaded }

        func transcribe(
            url: URL, options: TranscriptionOptions, handlers: TranscribeHandlers
        ) async throws -> Transcript {
            Transcript(
                segments: raw.enumerated().map { WhisperSegmentMapping.segment($1, id: $0) },
                language: "en",
                modelName: loaded ?? "?",
                sourceURL: url
            )
        }
    }

    private static func segment(
        _ start: Float, _ end: Float, _ text: String, spokenFrom: Float? = nil, to spokenTo: Float? = nil
    ) -> TranscriptionSegment {
        let parts = text.split(separator: " ")
        let first = spokenFrom ?? start
        let step = ((spokenTo ?? end) - first) / Float(parts.count)
        return TranscriptionSegment(
            start: start,
            end: end,
            text: " \(text)",
            words: parts.enumerated().map { index, word in
                .init(
                    word: " \(word)",
                    tokens: [],
                    start: first + Float(index) * step,
                    end: first + Float(index + 1) * step,
                    probability: 0.9
                )
            }
        )
    }

    private static let raw: [TranscriptionSegment] = [
        segment(0, 2, "So today we are going to"),
        segment(2.2, 4, "talk about the budget."),
        TranscriptionSegment(start: 4, end: 5, text: " ..."),
        segment(6, 8, "Subtitles by the Amara.org community"),
        segment(10, 28, "Right.", spokenFrom: 10.2, to: 10.6),
        segment(28.5, 30, "Next question."),
    ]

    private func fileRun() async throws -> Transcript {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-live-finish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audioURL = dir.appendingPathComponent("input.wav")
        try Data("RIFFstub".utf8).write(to: audioURL)

        let registry = EngineRegistry()
        let stub = MappedTranscriber(raw: Self.raw)
        await registry.register(engineID: .whisperKit, capabilities: .whisperKitDefaults) { _ in stub }
        let store = ModelStore(modelsDirectory: dir)
        try store.seedInstalledModel("openai_whisper-tiny")
        let session = TranscriptionSession(modelStore: store, registry: registry)
        return try await session.transcribe(
            source: FileAudioSource(url: audioURL),
            options: TranscriptionOptions(model: "openai_whisper-tiny", language: "en", wordTimestamps: true)
        )
    }

    private func liveTake() async -> Transcript {
        let session = StreamingTranscriptionSession()
        await session.appendConfirmed(ConfirmedAudioBatch(segments: Array(Self.raw.prefix(3)), audioWindow: [], windowStartSeconds: 0))
        await session.appendConfirmed(ConfirmedAudioBatch(segments: Array(Self.raw.dropFirst(3)), audioWindow: [], windowStartSeconds: 0))
        return await session.finishedTranscript(recordedURL: nil)
    }

    @Test("the saved take reads the same as the file run over the same segments")
    func liveTakeMatchesFileRun() async throws {
        let file = try await fileRun()
        let live = await liveTake()

        #expect(live.segments.map(\.text) == [
            "So today we are going to talk about the budget.",
            "Right.",
            "Next question.",
        ])
        #expect(live.segments == file.segments)
    }

    @Test("the saved take keeps word timings and clamps a padded span to them")
    func liveTakeKeepsWords() async throws {
        let live = await liveTake()

        let merged = try #require(live.segments.first)
        #expect(merged.words?.count == 10)
        #expect(merged.words?.first?.word == "So")
        let right = try #require(live.segments.first { $0.text == "Right." })
        #expect(abs(right.start - 10.2) < 0.001)
        #expect(abs(right.end - 10.6) < 0.001)
    }
}
