import Clocks
import Foundation
import Testing
@testable import ParolaCore

@Suite("Transcript cleanup")
struct TranscriptCleanupTests {
    private func transcript(_ segments: [TranscriptSegment]) -> Transcript {
        Transcript(segments: segments, language: "it", modelName: "mock")
    }

    @Test("blank segments with real timings are dropped")
    func dropsBlankSegments() {
        let input = transcript([
            TranscriptSegment(id: 0, start: 0, end: 1, text: "Buongiorno"),
            TranscriptSegment(id: 1, start: 6.18, end: 7.58, text: ""),
            TranscriptSegment(id: 2, start: 10, end: 10.72, text: "   "),
            TranscriptSegment(id: 3, start: 12, end: 13, text: "a tutti")
        ])

        let out = TranscriptCleanup.apply(to: input)

        #expect(out.segments.map(\.text) == ["Buongiorno", "a tutti"])
    }

    @Test("ids stay contiguous after a drop, words included")
    func reindexesAfterDrop() throws {
        let input = transcript([
            TranscriptSegment(
                id: 0, start: 0, end: 1, text: "uno",
                words: [WordTiming(id: "0-0", word: "uno", start: 0, end: 1, probability: 0.9)]
            ),
            TranscriptSegment(id: 1, start: 2, end: 3, text: ""),
            TranscriptSegment(
                id: 2, start: 4, end: 5, text: "due",
                words: [WordTiming(id: "2-0", word: "due", start: 4, end: 5, probability: 0.9)]
            )
        ])

        let out = TranscriptCleanup.apply(to: input)

        #expect(out.segments.map(\.id) == [0, 1])
        #expect(try #require(out.segments.last?.words).map(\.id) == ["1-0"])
    }

    @Test("a transcript with nothing to drop is left alone")
    func leavesCleanTranscriptAlone() {
        let input = transcript([
            TranscriptSegment(id: 0, start: 0, end: 1, text: "uno"),
            TranscriptSegment(id: 1, start: 1, end: 2, text: "due")
        ])

        #expect(TranscriptCleanup.apply(to: input).segments == input.segments)
    }
}

@Suite("Transcription session cleanup")
struct TranscriptionSessionCleanupTests {
    private func makeSession(
        segments: [TranscriptSegmentSeed]
    ) async throws -> (session: TranscriptionSession, audioURL: URL) {
        let registry = EngineRegistry()
        let response = MockTranscriberResponse(
            segments: segments,
            language: "it",
            modelName: "mock-whisper"
        )
        await registry.register(
            engineID: .whisperKit,
            capabilities: .whisperKitDefaults,
            factory: { _ in MockTranscriber.make(response: response, clock: ImmediateClock()) }
        )

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-cleanup-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let audioURL = dir.appendingPathComponent("input.wav")
        try Data("RIFFstub".utf8).write(to: audioURL)
        let store = ModelStore(modelsDirectory: dir)
        try store.seedInstalledModel("openai_whisper-tiny")
        return (TranscriptionSession(modelStore: store, registry: registry), audioURL)
    }

    @Test("blank engine segments never reach the caller")
    func sessionDropsBlankSegments() async throws {
        let (session, audioURL) = try await makeSession(segments: [
            TranscriptSegmentSeed(start: 0, end: 1, text: "Buongiorno"),
            TranscriptSegmentSeed(start: 6.18, end: 7.58, text: ""),
            TranscriptSegmentSeed(start: 12, end: 13, text: "a tutti")
        ])

        let transcript = try await session.transcribe(
            source: FileAudioSource(url: audioURL),
            options: TranscriptionOptions(model: "openai_whisper-tiny")
        )
        await session.unloadModel()

        #expect(transcript.segments.map(\.text) == ["Buongiorno", "a tutti"])
        #expect(transcript.segments.map(\.id) == [0, 1])
    }
}
