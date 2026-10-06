import Foundation
import Testing
@testable import ParolaCore

@Suite("Reading script builder")
struct ReadingScriptBuilderTests {
    private func segment(
        _ id: Int,
        _ text: String,
        start: Double,
        end: Double? = nil,
        speaker: String? = nil
    ) -> TranscriptSegment {
        TranscriptSegment(id: id, start: start, end: end ?? start + 1, text: text, speaker: speaker)
    }

    private func transcript(_ segments: [TranscriptSegment], translation: TranscriptTranslation? = nil) -> Transcript {
        Transcript(segments: segments, language: "en", modelName: "test", translation: translation)
    }

    private func anchored(_ anchor: ReadingAnchor, _ location: Int, _ length: Int) -> ReadingUnit.Anchored {
        ReadingUnit.Anchored(anchor: anchor, range: NSRange(location: location, length: length))
    }

    private func substring(_ text: String, _ range: NSRange) -> String {
        (text as NSString).substring(with: range)
    }

    private func firstAnchorText(in text: String, _ unit: ReadingUnit) -> String {
        unit.anchors.first.map { substring(text, $0.range) } ?? ""
    }

    // MARK: - Sentences and anchors

    @Test("each sentence of a segment becomes a unit anchored to its span")
    func sentencesAnchorToTheirSpan() throws {
        let units = ReadingScriptBuilder.transcript(
            transcript([segment(0, "Hello there. How are you?", start: 0)]),
            language: "en"
        )
        #expect(units.map(\.text) == ["Hello there.", "How are you?"])
        try #require(units.count == 2)
        #expect(units[0].anchors == [anchored(.segment(0), 0, 12)])
        #expect(units[1].anchors == [anchored(.segment(0), 13, 12)])
    }

    @Test("a sentence spanning two segments carries both anchors with their own ranges")
    func sentenceSpanningTwoSegments() throws {
        let units = ReadingScriptBuilder.transcript(
            transcript([
                segment(0, "Hello there,", start: 0, end: 1),
                segment(1, " how are you today? Fine.", start: 1, end: 2),
            ]),
            language: "en"
        )
        #expect(units.map(\.text) == ["Hello there, how are you today?", "Fine."])
        try #require(units.count == 2)
        #expect(units[0].anchors == [anchored(.segment(0), 0, 12), anchored(.segment(1), 1, 18)])
        #expect(units[1].anchors == [anchored(.segment(1), 20, 5)])
    }

    @Test("ranges count UTF-16 units of the stored segment text")
    func rangesAreUTF16() {
        let text = "  Caffè ☕️ pronto. Sì."
        let units = ReadingScriptBuilder.transcript(transcript([segment(0, text, start: 0)]), language: "it")
        #expect(units.map(\.text) == ["Caffè ☕️ pronto.", "Sì."])
        #expect(units.map { firstAnchorText(in: text, $0) } == ["Caffè ☕️ pronto.", "Sì."])
    }

    @Test("segments with no text are skipped")
    func emptySegmentsAreSkipped() {
        let units = ReadingScriptBuilder.transcript(
            transcript([segment(0, "One.", start: 0), segment(1, "  \n", start: 1), segment(2, "Two.", start: 2)]),
            language: nil
        )
        #expect(units.map(\.text) == ["One.", "Two."])
        #expect(units.flatMap(\.anchors).map(\.anchor) == [.segment(0), .segment(2)])
    }

    // MARK: - Turns and paragraphs

    @Test("a single-speaker transcript has no turn pauses")
    func singleSpeakerHasNoTurns() {
        let units = ReadingScriptBuilder.transcript(
            transcript([
                segment(0, "One.", start: 0, speaker: "Alice"),
                segment(1, "Two.", start: 1, speaker: nil),
                segment(2, "Three.", start: 2, speaker: "Alice"),
            ]),
            language: "en"
        )
        #expect(units.map(\.pauseAfter) == [0, 0, 0])
    }

    @Test("a speaker change adds the turn pause")
    func speakerChangeAddsTurnPause() {
        let units = ReadingScriptBuilder.transcript(
            transcript([
                segment(0, "One.", start: 0, speaker: "Alice"),
                segment(1, "Two.", start: 1, speaker: "Bob"),
            ]),
            language: "en"
        )
        #expect(units.map(\.pauseAfter) == [ReadingScriptBuilder.turnPause, 0])
        #expect(ReadingScriptBuilder.turnPause == 0.6)
    }

    @Test("A, nil, A is one run")
    func nilLabelNeverOpensATurn() {
        let units = ReadingScriptBuilder.transcript(
            transcript([
                segment(0, "One.", start: 0, speaker: "A"),
                segment(1, "Two.", start: 1, speaker: nil),
                segment(2, "Three.", start: 2, speaker: "  "),
                segment(3, "Four.", start: 3, speaker: "A"),
                segment(4, "Five.", start: 4, speaker: "B"),
            ]),
            language: "en"
        )
        #expect(units.map(\.pauseAfter) == [0, 0, 0, 0.6, 0])
    }

    @Test("Alice and Alice with a newline are the same speaker")
    func flattenedLabelIsNoTurn() {
        let units = ReadingScriptBuilder.transcript(
            transcript([
                segment(0, "One.", start: 0, speaker: "Alice"),
                segment(1, "Two.", start: 1, speaker: "Alice\n"),
                segment(2, "Three.", start: 2, speaker: "Bob"),
            ]),
            language: "en"
        )
        #expect(units.map(\.pauseAfter) == [0, 0.6, 0])
    }

    @Test("a 1.5 s gap adds the paragraph pause, a shorter one doesn't")
    func paragraphGap() {
        let units = ReadingScriptBuilder.transcript(
            transcript([
                segment(0, "One.", start: 0, end: 1),
                segment(1, "Two.", start: 1 + TranscriptParagraphRule.pauseSeconds, end: 3),
                segment(2, "Three.", start: 4.49, end: 5),
            ]),
            language: "en"
        )
        #expect(units.map(\.pauseAfter) == [0.35, 0, 0])
        #expect(ReadingScriptBuilder.paragraphPause == 0.35)
    }

    @Test("a speaker change after a long gap pauses for the turn only")
    func turnWinsOverParagraph() {
        let units = ReadingScriptBuilder.transcript(
            transcript([
                segment(0, "One.", start: 0, end: 1, speaker: "Alice"),
                segment(1, "Two.", start: 5, end: 6, speaker: "Bob"),
            ]),
            language: "en"
        )
        #expect(units.map(\.pauseAfter) == [0.6, 0])
    }

    @Test("a paragraph break ends the sentence even without a full stop")
    func runBoundaryEndsTheSentence() {
        let units = ReadingScriptBuilder.transcript(
            transcript([
                segment(0, "and then we left", start: 0, end: 1),
                segment(1, "the next morning", start: 4, end: 5),
            ]),
            language: "en"
        )
        #expect(units.map(\.text) == ["and then we left", "the next morning"])
    }

    // MARK: - Starting point

    @Test("from: skips earlier segments")
    func fromSkipsEarlierSegments() {
        let units = ReadingScriptBuilder.transcript(
            transcript([
                segment(0, "One.", start: 0),
                segment(1, "Two.", start: 1),
                segment(2, "Three.", start: 2),
            ]),
            from: 1,
            language: "en"
        )
        #expect(units.map(\.text) == ["Two.", "Three."])
        #expect(units.map(\.id) == [0, 1])
    }

    @Test("from: an unknown segment reads nothing")
    func fromUnknownSegmentIsEmpty() {
        let units = ReadingScriptBuilder.transcript(
            transcript([segment(0, "One.", start: 0)]),
            from: 42,
            language: "en"
        )
        #expect(units.isEmpty)
    }

    @Test("from: remembers the speaker shown before the starting segment")
    func fromKeepsTheShownSpeaker() {
        let units = ReadingScriptBuilder.transcript(
            transcript([
                segment(0, "One.", start: 0, speaker: "A"),
                segment(1, "Two.", start: 1, speaker: "B"),
                segment(2, "Three.", start: 2, speaker: nil),
                segment(3, "Four.", start: 3, speaker: "B"),
                segment(4, "Five.", start: 4, speaker: "A"),
            ]),
            from: 2,
            language: "en"
        )
        #expect(units.map(\.pauseAfter) == [0, 0.6, 0])
    }

    // MARK: - Length cap

    @Test("an over-long sentence splits at the last comma before the cap")
    func capSplitsAtPunctuation() throws {
        let first = String(repeating: "word ", count: 25) + "then, more"
        let second = String(repeating: " again", count: 20) + "."
        let text = first + second
        let units = ReadingScriptBuilder.transcript(transcript([segment(0, text, start: 0)]), language: "en")
        try #require(units.count == 2)
        #expect(units[0].text == String(repeating: "word ", count: 25) + "then,")
        #expect(units.allSatisfy { $0.text.count <= ReadingScriptBuilder.maxUnitLength })
        #expect(units.map { firstAnchorText(in: text, $0) } == units.map(\.text))
        #expect(units.map(\.pauseAfter) == [0, 0])
    }

    @Test("an over-long sentence without punctuation splits at spaces, never inside a word")
    func capSplitsAtSpaces() {
        let words = (0..<80).map { "parola\($0)" }
        let text = words.joined(separator: " ")
        let units = ReadingScriptBuilder.transcript(transcript([segment(0, text, start: 0)]), language: "it")
        #expect(units.count > 1)
        #expect(units.allSatisfy { $0.text.count <= ReadingScriptBuilder.maxUnitLength })
        #expect(units.flatMap { $0.text.split(separator: " ").map(String.init) } == words)
        #expect(units.map { firstAnchorText(in: text, $0) } == units.map(\.text))
    }

    @Test("a comma inside a number is no split point")
    func capIgnoresDecimalComma() {
        let text = String(repeating: "uno ", count: 45) + "3,5 " + String(repeating: "due ", count: 10) + "fine"
        let units = ReadingScriptBuilder.transcript(transcript([segment(0, text, start: 0)]), language: "it")
        #expect(units.count == 2)
        #expect(units.allSatisfy { !$0.text.hasSuffix("3,") })
        #expect(units.flatMap { $0.text.split(separator: " ") }.contains("3,5"))
    }

    @Test("an over-long sentence without spaces splits after a full-width comma")
    func capSplitsAtFullWidthComma() {
        let text = String(repeating: "我们", count: 60) + "，" + String(repeating: "今天", count: 60) + "。"
        let units = ReadingScriptBuilder.transcript(transcript([segment(0, text, start: 0)]), language: "zh-Hans")
        #expect(units.map(\.text) == [String(repeating: "我们", count: 60) + "，", String(repeating: "今天", count: 60) + "。"])
    }

    @Test("an early comma never leaves a tiny unit")
    func capSkipsAnEarlyComma() {
        let words = (0..<35).map { "word\($0)" }
        let text = "Well, " + words.joined(separator: " ") + "."
        let units = ReadingScriptBuilder.transcript(transcript([segment(0, text, start: 0)]), language: "en")
        #expect(units.count == 2)
        #expect(units.first?.text.hasPrefix("Well, word0") == true)
        #expect(units.dropLast().allSatisfy { $0.text.count >= ReadingScriptBuilder.minPieceLength })
        #expect(units.allSatisfy { $0.text.count <= ReadingScriptBuilder.maxUnitLength })
        #expect(units.map { firstAnchorText(in: text, $0) } == units.map(\.text))
    }

    @Test("an early space before an over-long word never leaves a tiny unit")
    func capSkipsAnEarlySpace() {
        let link = "https://example.com/" + String(repeating: "a", count: 230)
        let text = "See " + link + " for the details."
        let units = ReadingScriptBuilder.transcript(transcript([segment(0, text, start: 0)]), language: "en")
        #expect(units.map(\.text) == ["See " + link, "for the details."])
    }

    @Test("a single word longer than the cap stays whole")
    func capKeepsAnOverlongWord() {
        let word = String(repeating: "a", count: 250)
        let units = ReadingScriptBuilder.transcript(transcript([segment(0, word, start: 0)]), language: "en")
        #expect(units.map(\.text) == [word])
    }

    // MARK: - Empty units

    @Test("an emoji-only sentence folds into the previous unit")
    func emojiOnlyFoldsIntoPrevious() throws {
        let units = ReadingScriptBuilder.transcript(
            transcript([
                segment(0, "Hello.", start: 0, end: 1),
                segment(1, "🎉🎉", start: 3, end: 4),
                segment(2, "Bye.", start: 6, end: 7),
            ]),
            language: "en"
        )
        #expect(units.map(\.text) == ["Hello.", "Bye."])
        try #require(units.count == 2)
        #expect(units[0].anchors == [anchored(.segment(0), 0, 6), anchored(.segment(1), 0, 4)])
        #expect(units.map(\.pauseAfter) == [0.35, 0])
    }

    @Test("a punctuation-only sentence at the start folds into the next unit")
    func leadingEmptyFoldsIntoNext() throws {
        let units = ReadingScriptBuilder.transcript(
            transcript([
                segment(0, "...", start: 0, end: 1),
                segment(1, "Hello.", start: 3, end: 4),
            ]),
            language: "en"
        )
        #expect(units.map(\.text) == ["Hello."])
        try #require(units.count == 1)
        #expect(units[0].anchors == [anchored(.segment(0), 0, 3), anchored(.segment(1), 0, 6)])
        #expect(units[0].pauseAfter == 0)
    }

    @Test("an empty last unit leaves the last pause at zero")
    func trailingEmptyKeepsLastPauseZero() throws {
        let units = ReadingScriptBuilder.transcript(
            transcript([
                segment(0, "Hello.", start: 0, end: 1, speaker: "A"),
                segment(1, "Bye.", start: 1, end: 2, speaker: "B"),
                segment(2, "🎉", start: 2, end: 3, speaker: "A"),
            ]),
            language: "en"
        )
        #expect(units.map(\.text) == ["Hello.", "Bye."])
        #expect(units.map(\.pauseAfter) == [0.6, 0])
        try #require(units.count == 2)
        #expect(units[1].anchors.map(\.anchor) == [.segment(1), .segment(2)])
    }

    @Test("a transcript with nothing to say has no units")
    func nothingToSay() {
        let units = ReadingScriptBuilder.transcript(
            transcript([segment(0, "🎉", start: 0), segment(1, "  ", start: 1)]),
            language: "en"
        )
        #expect(units.isEmpty)
    }

    @Test("unit ids are dense and 0-based in reading order, and carry the language")
    func idsAreDense() {
        let units = ReadingScriptBuilder.transcript(
            transcript([
                segment(0, "One. Two.", start: 0, end: 1),
                segment(1, "🎉", start: 3, end: 4),
                segment(2, "Three. Four.", start: 6, end: 7),
            ]),
            language: "en-GB"
        )
        #expect(units.map(\.id) == Array(0..<units.count))
        #expect(units.count == 4)
        #expect(units.allSatisfy { $0.language == "en-GB" })
    }

    // MARK: - Italian abbreviation

    @Test("Italian text with Dott. keeps every word and maps back to the segment")
    func italianAbbreviation() {
        let text = "Buongiorno a tutti. Il Dott. Rossi arriverà alle dieci. Poi parliamo del budget."
        let units = ReadingScriptBuilder.transcript(transcript([segment(0, text, start: 0)]), language: "it")
        #expect(units.map(\.text).joined(separator: " ") == text)
        #expect(units.first?.text == "Buongiorno a tutti.")
        #expect(units.last?.text == "Poi parliamo del budget.")
        #expect(units.map { firstAnchorText(in: text, $0) } == units.map(\.text))
    }

    // MARK: - Translation

    @Test("a translation reads in segment order and skips segments without one")
    func translationOrder() throws {
        let original = transcript(
            [
                segment(5, "First.", start: 0, end: 1),
                segment(2, "Second.", start: 1, end: 2),
                segment(9, "Third.", start: 2, end: 3),
                segment(7, "Fourth.", start: 3, end: 4),
            ]
        )
        let translation = TranscriptTranslation(
            targetLanguage: "it",
            segments: [9: " Terzo.", 5: "Primo.", 7: "  "],
            createdAt: Date(timeIntervalSince1970: 0),
            provider: "test"
        )
        let units = ReadingScriptBuilder.translation(translation, of: original, language: "it")
        #expect(units.map(\.text) == ["Primo.", "Terzo."])
        #expect(units.map { $0.anchors.map(\.anchor) } == [[.translation(segmentID: 5)], [.translation(segmentID: 9)]])
        try #require(units.count == 2)
        #expect(units[1].anchors.first?.range == NSRange(location: 1, length: 6))
        #expect(units.allSatisfy { $0.language == "it" })
    }

    @Test("a translation keeps the original's turns and paragraph breaks")
    func translationKeepsTurns() {
        let original = transcript([
            segment(0, "One.", start: 0, end: 1, speaker: "Alice"),
            segment(1, "Two.", start: 1, end: 2, speaker: "Bob"),
            segment(2, "Three.", start: 2, end: 3, speaker: nil),
            segment(3, "Four.", start: 5, end: 6, speaker: "Bob"),
        ])
        let translation = TranscriptTranslation(
            targetLanguage: "it",
            segments: [0: "Uno.", 1: "Due.", 2: "Tre.", 3: "Quattro."],
            createdAt: Date(timeIntervalSince1970: 0),
            provider: "test"
        )
        let units = ReadingScriptBuilder.translation(translation, of: original, language: "it")
        #expect(units.map(\.pauseAfter) == [0.6, 0, 0.35, 0])
    }

    @Test("a boundary before an untranslated segment carries to the next translated one")
    func translationCarriesSkippedBoundaries() {
        let original = transcript([
            segment(0, "One.", start: 0, end: 1, speaker: "Alice"),
            segment(1, "Two.", start: 1, end: 2, speaker: "Bob"),
            segment(2, "Three.", start: 2, end: 3, speaker: "Bob"),
        ])
        let translation = TranscriptTranslation(
            targetLanguage: "it",
            segments: [0: "Uno.", 2: "Tre."],
            createdAt: Date(timeIntervalSince1970: 0),
            provider: "test"
        )
        let units = ReadingScriptBuilder.translation(translation, of: original, language: "it")
        #expect(units.map(\.text) == ["Uno.", "Tre."])
        #expect(units.map(\.pauseAfter) == [0.6, 0])
    }

    // MARK: - Summary

    @Test("a summary is read without markdown, then chapters, then action items, with no headings")
    func summarySections() throws {
        let summary = Summary(
            text: "# Overview\nThe **team** agreed on [the plan](https://example.com).\n\n- First _point_\n- Second point",
            chapters: [Chapter(id: "c1", title: "Intro", start: 0), Chapter(id: "c2", title: "Budget", start: 60)],
            actionItems: ["Send the **notes**", "1. Book the room"]
        )
        let units = ReadingScriptBuilder.summary(summary, language: "en")
        #expect(units.map(\.text) == [
            "Overview",
            "The team agreed on the plan.",
            "First point",
            "Second point",
            "Intro",
            "Budget",
            "Send the notes",
            "Book the room",
        ])
        #expect(units.map(\.pauseAfter) == [0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0])
        #expect(ReadingScriptBuilder.sectionPause == 0.5)
        #expect(units.map { $0.anchors.map(\.anchor) } == [
            [.summaryParagraph(0)],
            [.summaryParagraph(1)],
            [.summaryParagraph(2)],
            [.summaryParagraph(3)],
            [.chapter("c1")],
            [.chapter("c2")],
            [.actionItem(0)],
            [.actionItem(1)],
        ])
        try #require(units.count == 8)
        #expect(units.map { $0.anchors.first?.range } == [
            NSRange(location: 2, length: 8),
            NSRange(location: 0, length: 55),
            NSRange(location: 2, length: 12),
            NSRange(location: 2, length: 12),
            NSRange(location: 0, length: 5),
            NSRange(location: 0, length: 6),
            NSRange(location: 0, length: 16),
            NSRange(location: 3, length: 13),
        ])
        #expect(!units.contains { ["Chapters", "Action Items", "Summary"].contains($0.text) })
    }

    @Test("plain summary paragraphs get the paragraph pause and split into sentences")
    func summaryParagraphs() {
        let summary = Summary(text: "One. Two.\nThree.")
        let units = ReadingScriptBuilder.summary(summary, language: nil)
        #expect(units.map(\.text) == ["One.", "Two.", "Three."])
        #expect(units.map(\.pauseAfter) == [0, 0.35, 0])
        #expect(units.map { $0.anchors.map(\.anchor) } == [[.summaryParagraph(0)], [.summaryParagraph(0)], [.summaryParagraph(1)]])
        #expect(units.allSatisfy { $0.language == nil })
    }

    @Test("summary paragraphs are the non-blank lines of the summary text")
    func summaryParagraphRanges() {
        let text = "Intro line\n\n  \n- item\r\nlast"
        let ranges = ReadingScriptBuilder.summaryParagraphRanges(in: text)
        #expect(ranges.map { substring(text, $0) } == ["Intro line", "- item", "last"])
    }

    @Test("a summary with only chapters starts with the chapters")
    func summaryWithoutText() {
        let summary = Summary(text: "  ", chapters: [Chapter(id: "c1", title: "Intro", start: 0)])
        let units = ReadingScriptBuilder.summary(summary, language: "en")
        #expect(units.map(\.text) == ["Intro"])
        #expect(units.map(\.pauseAfter) == [0])
    }

    @Test("markdown stripping keeps words with inner underscores and drops markers")
    func strippingMarkdown() {
        let stripped = ReadingScriptBuilder.strippingMarkdown(
            "## Notes\n* **Bold** and __strong__ with `code`\n> quoted ~~old~~ file_name\n![logo](a.png) 3. 2 * 3\n- [x] Done"
        )
        #expect(stripped == "Notes\nBold and strong with code\nquoted old file_name\nlogo 3. 2 * 3\nDone")
    }

    @Test("a lone asterisk or underscore is text, not emphasis")
    func strippingKeepsLiteralMarkers() {
        #expect(ReadingScriptBuilder.strippingMarkdown("2 * 3 = 6, 5*4 and 3*2, a_b") == "2 * 3 = 6, 5*4 and 3*2, a_b")
        #expect(ReadingScriptBuilder.strippingMarkdown("**Alice:** said *yes* and __no__") == "Alice: said yes and no")
        #expect(ReadingScriptBuilder.strippingMarkdown("an *unclosed marker") == "an *unclosed marker")
    }

    @Test("a link whose address has parentheses reads as its text")
    func strippingLinkWithParentheses() {
        #expect(
            ReadingScriptBuilder.strippingMarkdown("See [the page](https://en.wikipedia.org/wiki/Rome_(city)) today.")
                == "See the page today."
        )
        #expect(ReadingScriptBuilder.strippingMarkdown("A [broken](link and more") == "A [broken](link and more")
    }

    @Test("a summary line with a literal asterisk keeps its range on the raw line")
    func summaryLiteralAsterisk() throws {
        let units = ReadingScriptBuilder.summary(Summary(text: "- Costs went up 2 * 3 times."), language: "en")
        #expect(units.map(\.text) == ["Costs went up 2 * 3 times."])
        try #require(units.count == 1)
        #expect(units[0].anchors == [anchored(.summaryParagraph(0), 2, 26)])
    }

    // MARK: - Dispatch

    @Test("build picks the builder for the source")
    func buildDispatches() {
        let summary = Summary(text: "Short summary.")
        let translation = TranscriptTranslation(
            targetLanguage: "it",
            segments: [0: "Ciao."],
            createdAt: Date(timeIntervalSince1970: 0),
            provider: "test"
        )
        var original = transcript([segment(0, "Hello.", start: 0), segment(1, "Bye.", start: 1)], translation: translation)
        original.summary = summary

        #expect(ReadingScriptBuilder.build(.transcript(fromSegment: 1), of: original, language: "en").map(\.text) == ["Bye."])
        #expect(ReadingScriptBuilder.build(.summary, of: original, language: "en").map(\.text) == ["Short summary."])
        #expect(ReadingScriptBuilder.build(.translation(language: "it"), of: original, language: "it").map(\.text) == ["Ciao."])
        #expect(ReadingScriptBuilder.build(.translation(language: "fr"), of: original, language: "fr").isEmpty)
        original.summary = nil
        #expect(ReadingScriptBuilder.build(.summary, of: original, language: "en").isEmpty)
    }

    // MARK: - Performance

    @Test(.disabled("benchmark: remove the trait and run with swift test -c release --filter benchmarkThreeThousandSegments"))
    func benchmarkThreeThousandSegments() {
        let sentences = [
            "We looked at the numbers for the third quarter, and they were better than expected.",
            "Marco will send the slides tomorrow morning.",
            "Does anyone have questions before we move on?",
            "I think we should keep the same plan for now",
        ]
        let mixed = transcript((0..<3_000).map { index in
            TranscriptSegment(
                id: index,
                start: Double(index) * 3,
                end: Double(index) * 3 + (index % 7 == 0 ? 1 : 2.9),
                text: " " + sentences[index % sentences.count],
                speaker: index % 11 == 0 ? "SPEAKER_0\(index % 3)" : nil
            )
        })
        let everyOneAParagraph = transcript((0..<3_000).map { index in
            TranscriptSegment(id: index, start: Double(index) * 3, end: Double(index) * 3 + 1, text: sentences[index % sentences.count])
        })
        let clock = ContinuousClock()
        for (name, input) in [("mixed", mixed), ("every segment a paragraph", everyOneAParagraph)] {
            var units: [ReadingUnit] = []
            let elapsed = clock.measure {
                units = ReadingScriptBuilder.transcript(input, language: "en")
            }
            print("ReadingScriptBuilder 3000 segments, \(name): \(units.count) units in \(elapsed)")
            #expect(!units.isEmpty)
        }
    }
}
