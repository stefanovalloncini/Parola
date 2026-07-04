import Foundation
import SwiftUI
import Testing
import ParolaCore
@testable import Parola

@MainActor
@Suite("Continuous transcript chunking")
struct ContinuousChunksTests {
    private func segment(_ id: Int, _ text: String, speaker: String? = nil) -> TranscriptSegment {
        TranscriptSegment(id: id, start: Double(id), end: Double(id) + 1, text: text, speaker: speaker)
    }

    private func build(
        _ segments: [TranscriptSegment],
        useSpeakerColor: Bool = false,
        softCap: Int = ContinuousChunks.softSegmentCap,
        hardCap: Int = ContinuousChunks.hardSegmentCap
    ) -> [ContinuousChunks.Chunk] {
        ContinuousChunks.build(segments: segments, useSpeakerColor: useSpeakerColor, softCap: softCap, hardCap: hardCap)
    }

    private func plainTexts(
        _ segments: [TranscriptSegment],
        useSpeakerColor: Bool = false,
        softCap: Int = ContinuousChunks.softSegmentCap,
        hardCap: Int = ContinuousChunks.hardSegmentCap
    ) -> [String] {
        build(segments, useSpeakerColor: useSpeakerColor, softCap: softCap, hardCap: hardCap)
            .map { String($0.text.characters) }
    }

    private func runText(in chunk: ContinuousChunks.Chunk, id: TranscriptSegment.ID) -> String? {
        guard let run = chunk.runs[id] else { return nil }
        let chars = chunk.text.characters
        guard
            let lo = chars.index(chars.startIndex, offsetBy: run.offsets.lowerBound, limitedBy: chars.endIndex),
            let hi = chars.index(chars.startIndex, offsetBy: run.offsets.upperBound, limitedBy: chars.endIndex)
        else { return nil }
        return String(chars[lo..<hi]).trimmingCharacters(in: .whitespaces)
    }

    private func linkColor(of id: TranscriptSegment.ID, in chunk: ContinuousChunks.Chunk) -> Color? {
        for run in chunk.text.runs where run.link?.absoluteString == "parola-seek://\(id)" {
            return run.foregroundColor
        }
        return nil
    }

    private func move(
        _ chunks: inout [ContinuousChunks.Chunk],
        from previousID: TranscriptSegment.ID?,
        to nextID: TranscriptSegment.ID?
    ) {
        ContinuousChunks.moveHighlight(
            in: &chunks,
            chunkIndexBySegment: ContinuousChunks.chunkIndexBySegment(for: chunks),
            from: previousID,
            to: nextID,
            highlightColor: .red
        )
    }

    // MARK: - Joining

    @Test("joins segments with a single space and no trailing space")
    func joinsWithSingleSpace() {
        let segments = [segment(0, "Hello."), segment(1, "World.")]
        #expect(plainTexts(segments) == ["Hello. World."])
    }

    @Test("a whitespace-only middle segment does not produce a double space")
    func middleEmptyNoDoubleSpace() {
        let segments = [segment(0, "Hello."), segment(1, "  \n\t "), segment(2, "World.")]
        #expect(plainTexts(segments) == ["Hello. World."])
    }

    @Test("a trailing whitespace-only segment leaves no trailing space")
    func trailingEmptyNoTrailingSpace() {
        let segments = [segment(0, "Hello."), segment(1, "   ")]
        #expect(plainTexts(segments) == ["Hello."])
    }

    @Test("a trailing empty segment after several real ones leaves no trailing space")
    func trailingEmptyAfterManyNoTrailingSpace() {
        let segments = [segment(0, "One"), segment(1, "two"), segment(2, "   ")]
        #expect(plainTexts(segments) == ["One two"])
    }

    @Test("a leading whitespace-only segment leaves no leading space")
    func leadingEmptyNoLeadingSpace() {
        let segments = [segment(0, "  "), segment(1, "World.")]
        #expect(plainTexts(segments) == ["World."])
    }

    @Test("rendered text matches the canonical Transcript.text")
    func matchesCanonicalText() {
        let segments = [segment(0, "Hello."), segment(1, "World."), segment(2, "  ")]
        let transcript = Transcript(segments: segments, language: "en", modelName: "test")
        #expect(plainTexts(segments).joined(separator: " ") == transcript.text)
    }

    @Test("cap splits preserve the canonical text when chunks are re-joined")
    func capSplitPreservesCanonicalText() {
        let segments = [segment(0, "Hello."), segment(1, "World.")]
        let transcript = Transcript(segments: segments, language: "en", modelName: "test")
        let texts = plainTexts(segments, softCap: 1, hardCap: 2)
        #expect(texts.count == 2)
        #expect(texts.joined(separator: " ") == transcript.text)
    }

    // MARK: - Speaker blocks

    @Test("a speaker change starts a new labelled chunk")
    func speakerChangeStartsNewChunk() {
        let segments = [
            segment(0, "Hi.", speaker: "Alice"),
            segment(1, "Yo.", speaker: "Bob"),
            segment(2, "   ", speaker: "Alice")
        ]
        #expect(plainTexts(segments, useSpeakerColor: true) == ["Alice\nHi.", "Bob\nYo."])
    }

    @Test("consecutive same-speaker segments stay in one chunk")
    func sameSpeakerRunStaysInline() {
        let segments = [
            segment(0, "Hi.", speaker: "Alice"),
            segment(1, "Still me.", speaker: "Alice"),
            segment(2, "Yo.", speaker: "Bob")
        ]
        #expect(plainTexts(segments, useSpeakerColor: true) == ["Alice\nHi. Still me.", "Bob\nYo."])
    }

    @Test("without speaker color the plain text has no labels")
    func noSpeakerColorHasNoLabels() {
        let segments = [
            segment(0, "Hi.", speaker: "Alice"),
            segment(1, "Yo.", speaker: "Bob")
        ]
        #expect(plainTexts(segments, useSpeakerColor: false) == ["Hi. Yo."])
    }

    // MARK: - Caps

    @Test("the soft cap splits a block at sentence ends")
    func softCapSplitsAtSentenceEnds() {
        let segments = (0..<8).map { segment($0, "Sentence \($0).") }
        let chunks = build(segments, softCap: 3, hardCap: 5)
        #expect(chunks.map(\.runs.count) == [3, 3, 2])
    }

    @Test("past the soft cap the break waits for a sentence end")
    func softCapWaitsForSentenceEnd() {
        let segments = [
            segment(0, "a"), segment(1, "b"), segment(2, "c"),
            segment(3, "d."), segment(4, "e"), segment(5, "f")
        ]
        #expect(plainTexts(segments, softCap: 3, hardCap: 6) == ["a b c d.", "e f"])
    }

    @Test("the hard cap breaks even without a sentence end")
    func hardCapBreaksWithoutSentenceEnd() {
        let segments = (0..<7).map { segment($0, "word\($0)") }
        let chunks = build(segments, softCap: 3, hardCap: 5)
        #expect(chunks.map(\.runs.count) == [5, 2])
    }

    @Test("default caps split a long single-speaker transcript at 40")
    func defaultCapsSplitLongBlock() {
        let segments = (0..<85).map { segment($0, "Sentence \($0).") }
        let chunks = build(segments)
        #expect(chunks.map(\.runs.count) == [40, 40, 5])
    }

    @Test("a continuation chunk repeats no speaker heading")
    func continuationChunkHasNoHeading() {
        let segments = (0..<5).map { segment($0, "S\($0).", speaker: "Alice") }
        let texts = plainTexts(segments, useSpeakerColor: true, softCap: 3, hardCap: 5)
        #expect(texts == ["Alice\nS0. S1. S2.", "S3. S4."])
    }

    // MARK: - Runs and links

    @Test("run offsets are chunk-local")
    func runOffsetsAreChunkLocal() {
        let segments = (0..<5).map { segment($0, "S\($0).", speaker: "Alice") }
        let chunks = build(segments, useSpeakerColor: true, softCap: 3, hardCap: 5)
        #expect(chunks.count == 2)
        #expect(chunks[1].runs[3]?.offsets.lowerBound == 0)
        #expect(runText(in: chunks[0], id: 0) == "S0.")
        #expect(runText(in: chunks[1], id: 3) == "S3.")
        #expect(runText(in: chunks[1], id: 4) == "S4.")
    }

    @Test("segment runs map to body text, not the speaker label")
    func runsMapToBodyNotLabel() {
        let segments = [
            segment(0, "Hi.", speaker: "Alice"),
            segment(1, "Still me.", speaker: "Alice"),
            segment(2, "Yo.", speaker: "Bob")
        ]
        let chunks = build(segments, useSpeakerColor: true)
        #expect(runText(in: chunks[0], id: 0) == "Hi.")
        #expect(runText(in: chunks[0], id: 1) == "Still me.")
        #expect(runText(in: chunks[1], id: 2) == "Yo.")
    }

    @Test("seek links stay in segment order across chunks")
    func seekLinksSpanChunksInOrder() {
        let segments = (0..<4).map { segment($0, "Sentence \($0).") }
        let chunks = build(segments, softCap: 2, hardCap: 3)
        let links = chunks.flatMap { $0.text.runs.compactMap(\.link?.absoluteString) }
        #expect(chunks.count == 2)
        #expect(links == ["parola-seek://0", "parola-seek://1", "parola-seek://2", "parola-seek://3"])
    }

    @Test("heading runs carry no seek link")
    func headingRunsCarryNoLink() {
        let segments = [segment(0, "Hi.", speaker: "Alice"), segment(1, "Yo.", speaker: "Bob")]
        let chunks = build(segments, useSpeakerColor: true)
        for chunk in chunks {
            #expect(chunk.text.runs.first?.link == nil)
            #expect(chunk.text.runs.compactMap(\.link).count == chunk.runs.count)
        }
    }

    @Test("chunkIndexBySegment maps every segment to its containing chunk")
    func chunkIndexMapsSegmentsToChunks() {
        let segments = (0..<5).map { segment($0, "S\($0).", speaker: "Alice") }
        let chunks = build(segments, useSpeakerColor: true, softCap: 3, hardCap: 5)
        let index = ContinuousChunks.chunkIndexBySegment(for: chunks)
        #expect(index == [0: 0, 1: 0, 2: 0, 3: 1, 4: 1])
    }

    // MARK: - Highlight

    @Test("moving the highlight recolors runs within a chunk and restores the old one")
    func highlightMovesWithinChunk() {
        let segments = [segment(0, "Hello."), segment(1, "World.")]
        var chunks = build(segments)
        move(&chunks, from: nil, to: 0)
        #expect(linkColor(of: 0, in: chunks[0]) == .red)
        move(&chunks, from: 0, to: 1)
        #expect(linkColor(of: 0, in: chunks[0]) == chunks[0].runs[0]?.baseColor)
        #expect(linkColor(of: 0, in: chunks[0]) != .red)
        #expect(linkColor(of: 1, in: chunks[0]) == .red)
    }

    @Test("de-highlighting restores the speaker display color, not nil")
    func dehighlightRestoresSpeakerColor() {
        let segments = [segment(0, "Hi.", speaker: "Alice"), segment(1, "Yo.", speaker: "Bob")]
        var chunks = build(segments, useSpeakerColor: true)
        move(&chunks, from: nil, to: 0)
        move(&chunks, from: 0, to: 1)
        #expect(linkColor(of: 0, in: chunks[0]) != nil)
        #expect(linkColor(of: 0, in: chunks[0]) == DS.speakerColor(for: "Alice"))
        #expect(linkColor(of: 1, in: chunks[1]) == .red)
    }

    @Test("the highlight crosses a chunk boundary and leaves other chunks untouched")
    func highlightCrossesChunkBoundary() {
        let segments = [
            segment(0, "Hi.", speaker: "Alice"),
            segment(1, "Yo.", speaker: "Bob"),
            segment(2, "Ciao.", speaker: "Cara")
        ]
        var chunks = build(segments, useSpeakerColor: true)
        let pristine = build(segments, useSpeakerColor: true)
        #expect(chunks.count == 3)
        move(&chunks, from: nil, to: 0)
        move(&chunks, from: 0, to: 2)
        #expect(linkColor(of: 0, in: chunks[0]) == chunks[0].runs[0]?.baseColor)
        #expect(linkColor(of: 2, in: chunks[2]) == .red)
        #expect(chunks[1].text == pristine[1].text)
    }

    @Test("moving the highlight to nil only restores")
    func highlightToNilRestores() {
        let segments = [segment(0, "Hello."), segment(1, "World.")]
        var chunks = build(segments)
        let pristine = build(segments)
        move(&chunks, from: nil, to: 1)
        move(&chunks, from: 1, to: nil)
        #expect(chunks[0].text == pristine[0].text)
    }

    @Test("an unknown segment id is a no-op")
    func unknownSegmentIsNoOp() {
        let segments = [segment(0, "Hello.")]
        var chunks = build(segments)
        let pristine = build(segments)
        move(&chunks, from: nil, to: 99)
        move(&chunks, from: 99, to: nil)
        #expect(chunks[0].text == pristine[0].text)
    }
}
