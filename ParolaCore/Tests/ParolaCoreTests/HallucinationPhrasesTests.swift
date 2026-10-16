import Clocks
import Foundation
import Testing
@testable import ParolaCore

@Suite("Built-in hallucination filter")
struct HallucinationPhrasesTests {
    private func seg(_ id: Int, _ text: String) -> TranscriptSegment {
        TranscriptSegment(id: id, start: Double(id), end: Double(id) + 1, text: text)
    }

    @Test("subtitle credits are dropped in several languages")
    func dropsKnownFiller() {
        let input = [
            seg(0, "Allora, ricominciamo"),
            seg(1, "Subtitles by the Amara.org community"),
            seg(2, "Sottotitoli e revisione a cura di QTSS"),
            seg(3, "Untertitel der Amara.org-Community"),
            seg(4, "字幕由Amara.org社区提供"),
            seg(5, "Sous-titrage Société Radio-Canada"),
            seg(6, "CC por Antarctica Films Argentina.")
        ]

        let out = IgnoredSegments.applyBuiltInDefaults(to: input)

        #expect(out.map(\.text) == ["Allora, ricominciamo"])
    }

    @Test("trailing punctuation does not decide the match")
    func punctuationInsensitive() {
        let input = [
            seg(0, "Sottotitoli a cura di QTSS"),
            seg(1, "Sottotitoli a cura di QTSS."),
            seg(2, "ok")
        ]

        let out = IgnoredSegments.applyBuiltInDefaults(to: input)

        #expect(out.map(\.text) == ["ok"])
    }

    @Test("a credit inside a longer sentence is left alone")
    func keepsSpokenContext() {
        let input = [
            seg(0, "Subtitles by the Amara.org community, as always."),
            seg(1, "E i sottotitoli a cura di QTSS li rifacciamo.")
        ]

        let out = IgnoredSegments.applyBuiltInDefaults(to: input)

        #expect(out.count == 2)
    }

    @Test("spoken thanks and outros survive the filter")
    func keepsSpokenThanks() {
        let input = [
            seg(0, "Thank you."),
            seg(1, "Thanks for watching."),
            seg(2, "谢谢观看"),
            seg(3, "ご視聴ありがとうございました。")
        ]

        let out = IgnoredSegments.applyBuiltInDefaults(to: input)

        #expect(out.count == 4)
    }

    @Test("cleanup keeps a spoken thanks")
    func cleanupKeepsSpokenThanks() {
        let transcript = Transcript(
            segments: [seg(0, "Grazie a tutti."), seg(1, "Thank you.")],
            language: "it",
            modelName: "openai_whisper-tiny"
        )

        let out = TranscriptCleanup.apply(to: transcript)

        #expect(out.segments.map(\.text) == ["Grazie a tutti.", "Thank you."])
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
        TranscriptSegmentSeed(start: 4, end: 5, text: "Sottotitoli a cura di QTSS"),
        TranscriptSegmentSeed(start: 8, end: 9, text: "Riprendiamo da qui.")
    ]

    @Test("the CLI and MCP path drops subtitle credits without any user rules")
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
