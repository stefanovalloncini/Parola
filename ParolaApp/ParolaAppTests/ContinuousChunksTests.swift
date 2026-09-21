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

    private func timed(
        _ id: Int,
        _ text: String,
        start: Double,
        end: Double,
        speaker: String? = nil
    ) -> TranscriptSegment {
        TranscriptSegment(id: id, start: start, end: end, text: text, speaker: speaker)
    }

    /// Segments back to back, then one that starts `gap` seconds after the previous ends.
    private func pairSeparatedBy(_ gap: Double) -> [TranscriptSegment] {
        [timed(0, "First.", start: 0, end: 4), timed(1, "Second.", start: 4 + gap, end: 8 + gap)]
    }

    private func build(
        _ segments: [TranscriptSegment],
        useSpeakerColor: Bool = false,
        speakerColorIndices: [String: Int] = [:],
        translations: [Int: String] = [:],
        softCap: Int = ContinuousChunks.softSegmentCap,
        hardCap: Int = ContinuousChunks.hardSegmentCap
    ) -> [ContinuousChunks.Chunk] {
        ContinuousChunks.build(
            segments: segments,
            useSpeakerColor: useSpeakerColor,
            speakerColorIndices: speakerColorIndices,
            primaryText: DS.Color.primaryText,
            favoriteColor: DS.Color.accent,
            favorites: [],
            translations: translations,
            translationColor: DS.Color.secondaryText,
            softCap: softCap,
            hardCap: hardCap
        )
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

    @Test("a translated chunk carries a second column in the same order")
    func translatedColumnFollowsTheOriginal() {
        let segments = [segment(0, "Ciao."), segment(1, "Come stai?")]
        let chunks = build(segments, translations: [0: "Hello.", 1: "How are you?"])

        #expect(chunks.count == 1)
        #expect(String(chunks[0].text.characters) == "Ciao. Come stai?")
        #expect(chunks[0].translation.map { String($0.characters) } == "Hello. How are you?")
    }

    @Test("a segment without a translation leaves the second column shorter")
    func untranslatedSegmentsAreSkippedInTheColumn() {
        let chunks = build([segment(0, "Ciao."), segment(1, "Come stai?")], translations: [1: "How are you?"])

        #expect(chunks[0].translation.map { String($0.characters) } == "How are you?")
    }

    @Test("a chunk with nothing translated carries no second column")
    func untranslatedChunkHasNoColumn() {
        let chunks = build([segment(0, "Ciao."), segment(1, "Come stai?")])

        #expect(chunks[0].translation == nil)
    }

    @Test("the translated column repeats the speaker heading so the two line up")
    func translatedColumnKeepsSpeakerHeadings() {
        let segments = [segment(0, "Ciao.", speaker: "Ada"), segment(1, "Ciao a te.", speaker: "Grace")]
        let chunks = build(segments, useSpeakerColor: true, translations: [0: "Hello.", 1: "Hello back."])

        #expect(chunks.map { $0.translation.map { String($0.characters) } } == ["Ada\nHello.", "Grace\nHello back."])
    }

    @Test("a chunk whose first segment is untranslated still heads its second column")
    func translatedColumnWaitsForItsFirstLine() {
        let segments = [segment(0, "Ciao.", speaker: "Ada"), segment(1, "Come stai?", speaker: "Ada")]
        let chunks = build(segments, useSpeakerColor: true, translations: [1: "How are you?"])

        #expect(chunks[0].translation.map { String($0.characters) } == "Ada\nHow are you?")
    }

    @Test("a paragraph break only reaches the second column once it has a line")
    func translatedColumnSkipsALeadingParagraphBreak() {
        let segments = [
            timed(0, "Ciao.", start: 0, end: 4),
            timed(1, "Come stai?", start: 20, end: 24),
        ]
        let chunks = build(segments, translations: [1: "How are you?"])

        #expect(chunks[0].translation.map { String($0.characters) } == "How are you?")
    }

    @Test("a new translation is a different signature")
    func translationChangesTheSignature() {
        let segments = [segment(0, "Ciao.")]
        let before = ContinuousChunks.contentSignature(
            segments: segments, useSpeakerColor: false, favoritesOnly: false, favorites: [],
            translations: [:], speakerColorIndices: [:]
        )
        let after = ContinuousChunks.contentSignature(
            segments: segments, useSpeakerColor: false, favoritesOnly: false, favorites: [],
            translations: [0: "Hello."], speakerColorIndices: [:]
        )

        #expect(before != after)
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

    // MARK: - Paragraphs

    @Test("a pause at the threshold starts a new paragraph")
    func pauseAtThresholdBreaksParagraph() {
        let texts = plainTexts(pairSeparatedBy(TranscriptDerive.paragraphPauseSeconds))
        #expect(texts == ["First.\n\nSecond."])
    }

    @Test("a long pause starts a new paragraph")
    func longPauseBreaksParagraph() {
        #expect(plainTexts(pairSeparatedBy(4)) == ["First.\n\nSecond."])
    }

    @Test("a pause under the threshold keeps one paragraph")
    func shortPauseKeepsOneParagraph() {
        #expect(plainTexts(pairSeparatedBy(1.4)) == ["First. Second."])
    }

    @Test("back-to-back segments keep one paragraph")
    func noGapKeepsOneParagraph() {
        #expect(plainTexts(pairSeparatedBy(0)) == ["First. Second."])
    }

    @Test("a paragraph break lands in the copied text as a blank line")
    func paragraphBreakSurvivesCopy() {
        let copied = plainTexts(pairSeparatedBy(3)).joined(separator: "\n\n")
        #expect(copied.components(separatedBy: "\n\n") == ["First.", "Second."])
    }

    @Test("run offsets stay aligned across a paragraph break")
    func runOffsetsSurviveParagraphBreak() {
        let chunks = build(pairSeparatedBy(3))
        #expect(chunks.count == 1)
        #expect(runText(in: chunks[0], id: 0) == "First.")
        #expect(runText(in: chunks[0], id: 1) == "Second.")
    }

    @Test("a whitespace-only segment does not swallow the pause around it")
    func blankSegmentKeepsThePause() {
        let segments = [
            timed(0, "First.", start: 0, end: 4),
            timed(1, "   ", start: 4, end: 5),
            timed(2, "Second.", start: 8, end: 12)
        ]
        #expect(plainTexts(segments) == ["First.\n\nSecond."])
    }

    @Test("a speaker change opens a chunk rather than a paragraph break")
    func speakerChangeWinsOverPause() {
        let segments = [
            timed(0, "Hi.", start: 0, end: 4, speaker: "Alice"),
            timed(1, "Yo.", start: 8, end: 12, speaker: "Bob")
        ]
        #expect(plainTexts(segments, useSpeakerColor: true) == ["Alice\nHi.", "Bob\nYo."])
    }

    @Test("past the soft cap a pause closes the chunk instead of adding a blank line")
    func pastSoftCapPauseClosesTheChunk() {
        let segments = [
            timed(0, "a", start: 0, end: 1),
            timed(1, "b", start: 1, end: 2),
            timed(2, "c", start: 2, end: 3),
            timed(3, "d", start: 6, end: 7)
        ]
        #expect(plainTexts(segments, softCap: 3, hardCap: 6) == ["a b c", "d"])
    }

    @Test("a pause right after a chunk break adds no leading blank line")
    func pauseAfterChunkBreakAddsNoLeadingBlankLine() {
        let segments = (0..<4).map { timed($0, "word\($0)", start: Double($0) * 10, end: Double($0) * 10 + 1) }
        #expect(plainTexts(segments, softCap: 2, hardCap: 2) == ["word0\n\nword1", "word2\n\nword3"])
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

    /// Tinting a whole paragraph made a three-speaker transcript read as three colours of body text.
    @Test("the speaker tint stays on the name; the paragraph under it is body text")
    func onlyTheHeadingCarriesTheSpeakerTint() {
        let segments = [segment(0, "Hi.", speaker: "Alice"), segment(1, "Yo.", speaker: "Bob")]
        let chunks = build(segments, useSpeakerColor: true)
        let heading = chunks[0].text.runs.first
        #expect(heading?.foregroundColor == DS.speakerColor(for: "Alice"))
        #expect(heading?.font == DS.Font.bodyStrong)
        #expect(chunks[0].runs[0]?.baseColor == DS.Color.primaryText)
        #expect(chunks[1].runs[1]?.baseColor == DS.Color.primaryText)
    }

    @Test("an assigned speaker wears the person's colour, an unassigned one its own hash")
    func headingsFollowThePersonColour() {
        let segments = [segment(0, "Hi.", speaker: "Alice"), segment(1, "Yo.", speaker: "Bob")]
        let chunks = build(segments, useSpeakerColor: true, speakerColorIndices: ["Alice": 3])
        #expect(chunks[0].text.runs.first?.foregroundColor == DS.speakerPalette[3])
        #expect(chunks[1].text.runs.first?.foregroundColor == DS.speakerColor(for: "Bob"))
    }

    @Test("a colour change alone rebuilds the chunks")
    func colourChangeMovesTheSignature() {
        let segments = [segment(0, "Hi.", speaker: "Alice")]
        func signature(_ indices: [String: Int]) -> Int {
            ContinuousChunks.contentSignature(
                segments: segments, useSpeakerColor: true, favoritesOnly: false, favorites: [],
                translations: [:], speakerColorIndices: indices
            )
        }
        #expect(signature([:]) != signature(["Alice": 2]))
        #expect(signature(["Alice": 2]) == signature(["Alice": 2]))
    }

    @Test("a heading links to its own assign popover, never to a seek")
    func headingRunsCarryTheAssignLink() {
        let segments = [segment(0, "Hi.", speaker: "Alice"), segment(1, "Yo.", speaker: "Bob")]
        let chunks = build(segments, useSpeakerColor: true)
        #expect(chunks.map(\.speaker) == ["Alice", "Bob"])
        #expect(chunks[0].text.runs.first?.link?.absoluteString == "parola-assign://0")
        #expect(chunks[1].text.runs.first?.link?.absoluteString == "parola-assign://1")
        for chunk in chunks {
            let seeks = chunk.text.runs.compactMap(\.link?.absoluteString).filter { $0.hasPrefix("parola-seek://") }
            #expect(seeks.count == chunk.runs.count)
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

    @Test("de-highlighting restores the body colour, not the speaker tint")
    func dehighlightRestoresBodyColor() {
        let segments = [segment(0, "Hi.", speaker: "Alice"), segment(1, "Yo.", speaker: "Bob")]
        var chunks = build(segments, useSpeakerColor: true)
        move(&chunks, from: nil, to: 0)
        move(&chunks, from: 0, to: 1)
        #expect(linkColor(of: 0, in: chunks[0]) != nil)
        #expect(linkColor(of: 0, in: chunks[0]) == DS.Color.primaryText)
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

    // MARK: - Build gate

    @Test("a fresh gate wants a build")
    func freshGateWantsBuild() {
        let gate = ContinuousChunks.BuildGate()
        #expect(gate.appliedSignature == nil)
        #expect(gate.needsRebuild(for: 7))
    }

    @Test("a build that never lands leaves the gate open for the next pass")
    func cancelledBuildLeavesGateOpen() {
        var gate = ContinuousChunks.BuildGate()
        #expect(gate.needsRebuild(for: 7))
        #expect(gate.needsRebuild(for: 7))

        gate.applied(7)

        #expect(!gate.needsRebuild(for: 7))
        #expect(gate.needsRebuild(for: 8))
    }

    @MainActor
    private final class GateBox {
        var gate = ContinuousChunks.BuildGate()

        func record(_ signature: Int) {
            gate.applied(signature)
        }
    }

    private func buildOffMain(_ segments: [TranscriptSegment], signature: Int, into box: GateBox) async {
        await ContinuousChunks.buildOffMain(
            segments: segments,
            useSpeakerColor: false,
            speakerColorIndices: [:],
            primaryText: DS.Color.primaryText,
            favoriteColor: DS.Color.accent,
            favorites: [],
            translations: [:],
            translationColor: DS.Color.secondaryText,
            signature: signature
        ) { _, applied in box.record(applied) }
    }

    @Test("a cancelled off-main build never claims its signature")
    func cancelledOffMainBuildLeavesGateOpen() async {
        let segments = (0..<(ContinuousChunks.synchronousBuildCap + 40)).map { segment($0, "Sentence \($0).") }
        let signature = ContinuousChunks.contentSignature(
            segments: segments, useSpeakerColor: false, favoritesOnly: false, favorites: [],
            translations: [:], speakerColorIndices: [:]
        )
        let box = GateBox()

        let cancelled = Task { await buildOffMain(segments, signature: signature, into: box) }
        cancelled.cancel()
        await cancelled.value

        #expect(box.gate.appliedSignature == nil)
        #expect(box.gate.needsRebuild(for: signature))

        await buildOffMain(segments, signature: signature, into: box)

        #expect(box.gate.appliedSignature == signature)
        #expect(!box.gate.needsRebuild(for: signature))
    }

    @Test("clearing the transcript reopens the gate for the signature it had built")
    func resetReopensGate() {
        var gate = ContinuousChunks.BuildGate()
        gate.applied(7)
        #expect(!gate.needsRebuild(for: 7))

        gate.reset()

        #expect(gate.appliedSignature == nil)
        #expect(gate.needsRebuild(for: 7))
    }
}
