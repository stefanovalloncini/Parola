import Clocks
import Foundation
import Testing
@testable import ParolaCore

@Suite("Built-in hallucination filter")
struct HallucinationPhrasesTests {
    private func seg(_ id: Int, _ text: String) -> TranscriptSegment {
        TranscriptSegment(id: id, start: Double(id), end: Double(id) + 1, text: text)
    }

    @Test("stock whisper filler is dropped in several languages")
    func dropsKnownFiller() {
        let input = [
            seg(0, "Allora, ricominciamo"),
            seg(1, "Thank you."),
            seg(2, "시청해주셔서 감사합니다."),
            seg(3, "Sottotitoli e revisione a cura di QTSS"),
            seg(4, "ご視聴ありがとうございました"),
            seg(5, "Продолжение следует...")
        ]

        let out = IgnoredSegments.applyBuiltInDefaults(to: input)

        #expect(out.map(\.text) == ["Allora, ricominciamo"])
    }

    @Test("trailing punctuation does not decide the match")
    func punctuationInsensitive() {
        let input = [seg(0, "Thanks for watching"), seg(1, "Thanks for watching!"), seg(2, "ok")]

        let out = IgnoredSegments.applyBuiltInDefaults(to: input)

        #expect(out.map(\.text) == ["ok"])
    }

    @Test("filler inside a longer sentence is left alone")
    func keepsSpokenContext() {
        let input = [seg(0, "Thank you for the coffee."), seg(1, "E quindi thank you.")]

        let out = IgnoredSegments.applyBuiltInDefaults(to: input)

        #expect(out.count == 2)
    }

    @Test("user rules do not pick up the built-in list")
    func userRulesStayUserRules() {
        let input = [seg(0, "Thank you."), seg(1, "uh")]

        let out = IgnoredSegments.apply(rules: [IgnoredSegmentRule(pattern: "uh")], to: input)

        #expect(out.map(\.text) == ["Thank you."])
    }
}

@Suite("Transcription session hallucination filter")
struct TranscriptionSessionHallucinationTests {
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
            .appendingPathComponent("parola-filler-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let audioURL = dir.appendingPathComponent("input.wav")
        try Data("RIFFstub".utf8).write(to: audioURL)
        let store = ModelStore(modelsDirectory: dir)
        try store.seedInstalledModel("openai_whisper-tiny")
        return (TranscriptionSession(modelStore: store, registry: registry), audioURL)
    }

    private let seeds = [
        TranscriptSegmentSeed(start: 0, end: 1, text: "Buongiorno a tutti."),
        TranscriptSegmentSeed(start: 4, end: 5, text: "시청해주셔서 감사합니다."),
        TranscriptSegmentSeed(start: 8, end: 9, text: "Riprendiamo da qui.")
    ]

    @Test("the CLI and MCP path drops stock filler without any user rules")
    func filtersByDefault() async throws {
        let (session, audioURL) = try await makeSession(segments: seeds)

        let transcript = try await session.transcribe(
            source: FileAudioSource(url: audioURL),
            options: TranscriptionOptions(model: "openai_whisper-tiny")
        )
        await session.unloadModel()

        #expect(transcript.segments.map(\.text) == ["Buongiorno a tutti.", "Riprendiamo da qui."])
    }

    @Test("the flag restores the raw engine output")
    func flagSuppressesDefaults() async throws {
        let (session, audioURL) = try await makeSession(segments: seeds)

        let transcript = try await session.transcribe(
            source: FileAudioSource(url: audioURL),
            options: TranscriptionOptions(
                model: "openai_whisper-tiny", filtersHallucinations: false
            )
        )
        await session.unloadModel()

        #expect(transcript.segments.count == 3)
    }
}
