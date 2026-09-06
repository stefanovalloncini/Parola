import Clocks
import Foundation
import Testing
import SpeakerKit
@testable import ParolaCore

@Suite("Sentence-aware segment merging")
struct SentenceMergerTests {
    private func seg(
        _ id: Int,
        _ start: Double,
        _ end: Double,
        _ text: String,
        speaker: String? = nil,
        words: Bool = false
    ) -> TranscriptSegment {
        let timings: [WordTiming]? = words ? wordTimings(id: id, start: start, end: end, text: text) : nil
        return TranscriptSegment(id: id, start: start, end: end, text: text, speaker: speaker, words: timings)
    }

    private func wordTimings(id: Int, start: Double, end: Double, text: String) -> [WordTiming] {
        let tokens = text.split(separator: " ")
        let step = (end - start) / Double(tokens.count)
        return tokens.enumerated().map { index, token in
            WordTiming(
                id: "\(id)-\(index)",
                word: String(token),
                start: start + step * Double(index),
                end: start + step * Double(index + 1),
                probability: 0.8
            )
        }
    }

    private func medianWordsPerSegment(_ segments: [TranscriptSegment]) -> Double {
        let counts = segments.map { $0.text.split(separator: " ").count }.sorted()
        guard !counts.isEmpty else { return 0 }
        let middle = counts.count / 2
        if counts.count.isMultiple(of: 2) {
            return Double(counts[middle - 1] + counts[middle]) / 2
        }
        return Double(counts[middle])
    }

    /// Shaped like the choppy whisper output this pass exists for: runs of one-word segments
    /// with sub-second gaps, broken only where the decoder put a full stop.
    private var choppyFixture: [TranscriptSegment] {
        [
            seg(0, 0.0, 0.6, "Allora"),
            seg(1, 0.7, 1.4, "vediamo"),
            seg(2, 1.5, 2.2, "come"),
            seg(3, 2.3, 3.0, "funziona"),
            seg(4, 3.1, 4.0, "questa cosa qui."),
            seg(5, 4.5, 5.2, "Poi"),
            seg(6, 5.3, 6.0, "dopo"),
            seg(7, 6.1, 6.9, "ne parliamo meglio."),
            seg(8, 7.5, 8.2, "Sì"),
            seg(9, 8.3, 9.0, "certo"),
            seg(10, 9.1, 9.9, "va bene così"),
            seg(11, 10.0, 11.0, "e andiamo avanti."),
            seg(12, 11.5, 12.3, "Un attimo"),
            seg(13, 12.4, 13.2, "che controllo"),
            seg(14, 13.3, 14.4, "il documento.")
        ]
    }

    @Test("the median segment grows from one word to a sentence")
    func medianRises() {
        let merged = SentenceMerger.merged(choppyFixture)

        #expect(medianWordsPerSegment(choppyFixture) <= 1)
        #expect(medianWordsPerSegment(merged) >= 6)
    }

    @Test("merging moves no words around")
    func textIsPreserved() {
        let before = choppyFixture.map(\.text).joined(separator: " ").filter { !$0.isWhitespace }

        let after = SentenceMerger.merged(choppyFixture)
            .map(\.text).joined(separator: " ").filter { !$0.isWhitespace }

        #expect(after == before)
    }

    @Test("a merged segment spans its parts and stays ordered")
    func timingsSpanTheParts() throws {
        let merged = SentenceMerger.merged(choppyFixture)

        let first = try #require(merged.first)
        #expect(first.start == 0.0)
        #expect(first.end == 4.0)
        #expect(zip(merged, merged.dropFirst()).allSatisfy { $0.end <= $1.start })
    }

    @Test("word timings survive the merge in order")
    func wordsAreConcatenated() throws {
        let input = [
            seg(0, 0.0, 0.6, "prima", words: true),
            seg(1, 0.7, 1.4, "parte", words: true),
            seg(2, 1.5, 2.4, "del discorso.", words: true)
        ]

        let merged = SentenceMerger.merged(input)

        #expect(merged.count == 1)
        let words = try #require(merged.first?.words)
        #expect(words.map(\.word) == ["prima", "parte", "del", "discorso."])
        #expect(zip(words, words.dropFirst()).allSatisfy { $0.start <= $1.start })
    }

    @Test("a segment that already ends a sentence is left where it is")
    func stopsAtTerminalPunctuation() {
        let input = [
            seg(0, 0.0, 1.0, "Ecco fatto."),
            seg(1, 1.1, 2.0, "Ora tocca a te.")
        ]

        #expect(SentenceMerger.merged(input).count == 2)
    }

    @Test("a long pause ends the run even mid-sentence")
    func stopsAtLongGap() {
        let input = [
            seg(0, 0.0, 1.0, "e poi"),
            seg(1, 4.0, 5.0, "siamo ripartiti")
        ]

        #expect(SentenceMerger.merged(input).count == 2)
    }

    @Test("the word cap keeps a merged segment readable")
    func stopsAtWordCap() {
        let input = (0..<12).map { index in
            seg(index, Double(index) * 1.0, Double(index) * 1.0 + 0.9, "una due tre")
        }

        let merged = SentenceMerger.merged(input)

        #expect(merged.count > 1)
        #expect(merged.allSatisfy { $0.text.split(separator: " ").count <= 16 })
    }

    @Test("segments from different speakers are never joined")
    func keepsSpeakersApart() {
        let input = [
            seg(0, 0.0, 1.0, "e allora", speaker: "Speaker 1"),
            seg(1, 1.1, 2.0, "dicevo", speaker: "Speaker 2")
        ]

        #expect(SentenceMerger.merged(input).count == 2)
    }

    @Test("a segment without word timings does not swallow one that has them")
    func doesNotMixTimedAndUntimed() {
        let input = [
            seg(0, 0.0, 1.0, "senza tempi"),
            seg(1, 1.1, 2.0, "con tempi", words: true)
        ]

        #expect(SentenceMerger.merged(input).count == 2)
    }

    @Test("a run that begins with punctuation joins without a stray space")
    func joinsPunctuationTightly() {
        let input = [
            seg(0, 0.0, 1.0, "va bene"),
            seg(1, 1.1, 2.0, ", direi di sì.")
        ]

        #expect(SentenceMerger.merged(input).map(\.text) == ["va bene, direi di sì."])
    }
}

@Suite("Transcription session sentence merging")
struct TranscriptionSessionMergeTests {
    private func makeSession(
        engineID: EngineID,
        model: String,
        segments: [TranscriptSegmentSeed]
    ) async throws -> (session: TranscriptionSession, audioURL: URL) {
        let registry = EngineRegistry()
        let response = MockTranscriberResponse(segments: segments, language: "it", modelName: "mock")
        await registry.register(
            engineID: engineID,
            capabilities: .whisperKitDefaults,
            factory: { _ in MockTranscriber.make(response: response, clock: ImmediateClock()) }
        )

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-merge-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let audioURL = dir.appendingPathComponent("input.wav")
        try Data("RIFFstub".utf8).write(to: audioURL)
        let store = ModelStore(modelsDirectory: dir)
        try store.seedInstalledModel(model)
        return (TranscriptionSession(modelStore: store, registry: registry), audioURL)
    }

    private let choppySeeds = [
        TranscriptSegmentSeed(start: 0.0, end: 0.6, text: "Allora"),
        TranscriptSegmentSeed(start: 0.7, end: 1.4, text: "vediamo"),
        TranscriptSegmentSeed(start: 1.5, end: 2.4, text: "come va.")
    ]

    @Test("whisper output comes back merged")
    func mergesWhisperOutput() async throws {
        let (session, audioURL) = try await makeSession(
            engineID: .whisperKit, model: "openai_whisper-tiny", segments: choppySeeds
        )

        let transcript = try await session.transcribe(
            source: FileAudioSource(url: audioURL),
            options: TranscriptionOptions(model: "openai_whisper-tiny")
        )
        await session.unloadModel()

        #expect(transcript.segments.map(\.text) == ["Allora vediamo come va."])
    }

    private let turnSeeds = [
        TranscriptSegmentSeed(start: 0.0, end: 1.0, text: "e questo"),
        TranscriptSegmentSeed(start: 1.3, end: 2.0, text: "è quanto"),
        TranscriptSegmentSeed(start: 2.3, end: 3.0, text: "sì certo"),
        TranscriptSegmentSeed(start: 3.3, end: 4.0, text: "come dicevi")
    ]

    @Test("the diarizer's labels reach the merge, so no segment spans a speaker change")
    func mergesAfterDiarization() async throws {
        let (session, audioURL) = try await makeSession(
            engineID: .whisperKit, model: "openai_whisper-tiny", segments: turnSeeds
        )
        await session.useDiarization { transcript, _, _ in
            var labelled = transcript
            labelled.segments = transcript.segments.enumerated().map { index, segment in
                var copy = segment
                copy.speaker = index.isMultiple(of: 2) ? "Speaker 1" : "Speaker 2"
                return copy
            }
            return labelled
        }

        let transcript = try await session.transcribe(
            source: FileAudioSource(url: audioURL),
            options: TranscriptionOptions(model: "openai_whisper-tiny", diarize: true)
        )
        await session.unloadModel()

        #expect(transcript.segments.map(\.text) == turnSeeds.map(\.text))
        #expect(transcript.segments.map(\.speaker) == ["Speaker 1", "Speaker 2", "Speaker 1", "Speaker 2"])
    }

    @Test("the same fragments come back as one turn when nothing labels them")
    func mergesTurnsWithoutDiarization() async throws {
        let (session, audioURL) = try await makeSession(
            engineID: .whisperKit, model: "openai_whisper-tiny", segments: turnSeeds
        )

        let transcript = try await session.transcribe(
            source: FileAudioSource(url: audioURL),
            options: TranscriptionOptions(model: "openai_whisper-tiny")
        )
        await session.unloadModel()

        #expect(transcript.segments.count == 1)
    }

    @Test("another engine's segmentation is left as the engine made it")
    func leavesOtherEnginesAlone() async throws {
        let (session, audioURL) = try await makeSession(
            engineID: .parakeet, model: "nvidia_parakeet-tdt-0.6b-v2", segments: choppySeeds
        )

        let transcript = try await session.transcribe(
            source: FileAudioSource(url: audioURL),
            options: TranscriptionOptions(model: "nvidia_parakeet-tdt-0.6b-v2", language: "en")
        )
        await session.unloadModel()

        #expect(transcript.segments.count == 3)
    }
}

@Suite("Merging around diarization")
struct DiarizedMergeTests {
    private let fragments = [
        TranscriptSegment(id: 0, start: 0.0, end: 1.0, text: "e questo"),
        TranscriptSegment(id: 1, start: 1.3, end: 2.0, text: "è quanto"),
        TranscriptSegment(id: 2, start: 2.3, end: 3.0, text: "sì certo"),
        TranscriptSegment(id: 3, start: 3.3, end: 4.0, text: "come dicevi")
    ]

    private var alternatingSpeakers: DiarizationResult {
        DiarizationResult(
            speakerCount: 2,
            totalFrames: 450,
            frameRate: 100,
            segments: [
                SpeakerSegment(speaker: .speakerId(0), startTime: 0, endTime: 1.15, frameRate: 100),
                SpeakerSegment(speaker: .speakerId(1), startTime: 1.15, endTime: 2.15, frameRate: 100),
                SpeakerSegment(speaker: .speakerId(0), startTime: 2.15, endTime: 3.15, frameRate: 100),
                SpeakerSegment(speaker: .speakerId(1), startTime: 3.15, endTime: 4.5, frameRate: 100)
            ]
        )
    }

    @Test("the merge the session runs after diarization stops at every speaker change")
    func mergeAfterDiarizationKeepsTurns() {
        let transcript = Transcript(segments: fragments, language: "it", modelName: "mock")

        let dropped = TranscriptCleanup.apply(
            to: transcript,
            options: TranscriptCleanupOptions(mergesSentences: false)
        )
        let diarized = DiarizationService.merge(transcript: dropped, diarization: alternatingSpeakers)
        let out = TranscriptCleanup.apply(
            to: diarized,
            options: TranscriptCleanupOptions(filtersHallucinations: false, mergesSentences: true)
        )

        #expect(out.segments.map(\.text) == fragments.map(\.text))
        #expect(out.segments.map(\.speaker) == ["Speaker 1", "Speaker 2", "Speaker 1", "Speaker 2"])
    }

    @Test("merging first would have joined the whole exchange into one turn")
    func mergeBeforeDiarizationStraddlesTurns() {
        #expect(SentenceMerger.merged(fragments).count == 1)
    }
}
