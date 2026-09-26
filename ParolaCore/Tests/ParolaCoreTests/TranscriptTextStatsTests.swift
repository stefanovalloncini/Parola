import Foundation
import Testing
@testable import ParolaCore

/// The counters as they were before `TranscriptTextStats` folded them into one walk.
private enum LegacyCounters {
    static func fillers(in text: String, fillers: [String] = FillerWordCounter.defaultFillers) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let flattened = trimmed.lowercased().map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : " "
        }
        let haystack = " " + String(flattened) + " "
        var total = 0
        for filler in fillers {
            let needle = " \(filler) "
            var range = haystack.startIndex..<haystack.endIndex
            while let hit = haystack.range(of: needle, range: range) {
                total += 1
                range = haystack.index(before: hit.upperBound)..<haystack.endIndex
            }
        }
        return total
    }

    static func sentences(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        var sentences = 0
        var insideSentence = false
        var previousWasDigit = false
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let char = trimmed[index]
            let next = trimmed.index(after: index)
            index = next
            if char.isWhitespace || char.isNewline {
                previousWasDigit = false
                continue
            }
            if char == "." || char == "!" || char == "?" {
                let nextIsDigit = next < trimmed.endIndex && trimmed[next].isNumber
                if char == "." && previousWasDigit && nextIsDigit {
                    previousWasDigit = false
                    continue
                }
                if insideSentence {
                    sentences += 1
                    insideSentence = false
                }
                previousWasDigit = false
            } else {
                insideSentence = true
                previousWasDigit = char.isNumber
            }
        }
        if insideSentence { sentences += 1 }
        return sentences
    }

    static func stats(_ transcript: Transcript, stopWords: Set<String>, limit: Int) -> TranscriptTextStats {
        var stats = TranscriptTextStats()
        let text = transcript.text
        stats.segmentWordCounts = transcript.segments.map { $0.text.split { !$0.isLetter && !$0.isNumber }.count }
        guard !text.isEmpty else { return stats }
        stats.charCount = text.count
        stats.wordCount = text.split { $0.isWhitespace || $0.isNewline }.count
        stats.sentenceCount = sentences(text)
        stats.fillerCount = fillers(in: text)
        stats.topWords = WordFrequency.compute(text: text, limit: limit, stopWords: stopWords)
        return stats
    }
}

/// Deterministic text built from pieces that stress the tokenizers: fillers, accents, emoji, digits, apostrophes, odd whitespace.
private struct FuzzText {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    private mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }

    private static let words = [
        "um", "Um", "UM", "uh", "uhm", "er", "erm", "like", "LIKE", "basically", "Actually", "literally", "really",
        "you", "know", "You", "KNOW", "i", "I", "mean", "sort", "of", "kind", "Kind", "so", "So", "well", "Well",
        "umbrella", "likewise", "sofa", "the", "and", "perché", "caffè", "Città", "cafe\u{301}", "naïve", "ÉCOLE",
        "straße", "İstanbul", "\u{212A}ind", "don't", "it\u{2019}s", "'quoted'", "rock'n'roll", "3", "3.5", "2020",
        "v2", "x86", "日本語", "中文", "한국어", "Ελληνικά", "Москва", "👍", "👍🏽", "👩‍👩‍👧", "🇮🇹", "a", "ab", "'", "''",
    ]
    private static let gaps = [
        " ", " ", " ", " ", "  ", ", ", ". ", "! ", "? ", "... ", "\n", "\r\n", "\t", "\u{00A0}", "\u{2028}", "\u{0085}",
        " - ", "-", "—", "'", "’", ".", "?!", ": ", "; ", " (", ") ", "\"", "…",
    ]

    mutating func sentence() -> String {
        var out = ""
        for position in 0..<(1 + next(14)) {
            if position > 0 { out += Self.gaps[next(Self.gaps.count)] }
            out += Self.words[next(Self.words.count)]
        }
        if next(3) == 0 { out += [".", "!", "?", "", " ", "  \n"][next(6)] }
        if next(5) == 0 { out = [" ", "\n", "\t "][next(3)] + out }
        return out
    }

    mutating func transcript(segments: Int) -> Transcript {
        let texts = (0..<segments).map { _ in next(12) == 0 ? ["", "   ", "\n"][next(3)] : sentence() }
        return Transcript(
            segments: texts.enumerated().map { index, text in
                TranscriptSegment(id: index, start: Double(index), end: Double(index) + 1, text: text)
            },
            language: "en",
            modelName: "tiny"
        )
    }
}

@Suite("Transcript text stats")
struct TranscriptTextStatsTests {
    @Test("one walk counts what the separate counters counted, over fuzzed transcripts")
    func matchesTheSeparateCounters() throws {
        var fuzz = FuzzText(seed: 42)
        let italian = WordFrequency.stopWords(for: "it")
        var fillers = 0
        for round in 0..<200 {
            let transcript = fuzz.transcript(segments: 1 + round % 40)
            let stopWords = round.isMultiple(of: 2) ? WordFrequency.defaultStopWords : italian
            let limit = round.isMultiple(of: 3) ? 12 : 20
            let expected = LegacyCounters.stats(transcript, stopWords: stopWords, limit: limit)
            let actual = try TranscriptTextStats.compute(segments: transcript.segments, stopWords: stopWords, topWordLimit: limit)
            try #require(actual == expected, "round \(round): \(transcript.segments.map(\.text))")
            fillers += actual.fillerCount
        }
        #expect(fillers > 500)
    }

    @Test("the filler and sentence counters agree with their old scans on fuzzed text")
    func countersMatchTheirOldScans() throws {
        var fuzz = FuzzText(seed: 7)
        for round in 0..<500 {
            let text = (0..<(1 + round % 6)).map { _ in fuzz.sentence() }.joined(separator: ["", " ", "\n"][round % 3])
            try #require(FillerWordCounter.count(in: text) == LegacyCounters.fillers(in: text), "\(text)")
            try #require(SentenceCounter.count(text) == LegacyCounters.sentences(text), "\(text)")
        }
    }

    @Test("custom fillers keep their old counts, spaced and repeated ones included")
    func customFillers() {
        let fillers = ["um um", "you know you", "um", "um", "o'clock", "Like", "", " so", "well  well", "so "]
        let texts = [
            "um um um um", "you know you know you know", "Um, um. UM um", "so so, so well well  well",
            "o'clock like LIKE", "  so  ", "",
        ]
        for text in texts {
            #expect(FillerWordCounter.count(in: text, fillers: fillers) == LegacyCounters.fillers(in: text, fillers: fillers), "\(text)")
        }
    }

    @Test("segments join with one space, so a phrase runs across a segment boundary")
    func segmentsJoinLikeTheTranscriptText() throws {
        let transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: " You"),
                TranscriptSegment(id: 1, start: 1, end: 2, text: "   "),
                TranscriptSegment(id: 2, start: 2, end: 3, text: "know it costs 3"),
                TranscriptSegment(id: 3, start: 3, end: 4, text: ".5 euro. Don't worry"),
            ],
            language: "en",
            modelName: "tiny"
        )
        let stats = try TranscriptTextStats.compute(segments: transcript.segments)
        #expect(stats.charCount == transcript.text.count)
        #expect(stats.wordCount == 9)
        #expect(stats.fillerCount == 1)
        #expect(stats.sentenceCount == 3)
        #expect(stats.segmentWordCounts == [1, 0, 4, 5])
        #expect(stats.topWords.map(\.word) == ["costs", "don't", "euro", "know", "worry"])
        #expect(stats == LegacyCounters.stats(transcript, stopWords: WordFrequency.defaultStopWords, limit: 20))
    }

    @Test("the ASCII shortcut answers as the Unicode properties do")
    func asciiKindsMatchTheProperties() {
        let characters = (0..<128).compactMap { Unicode.Scalar($0).map(Character.init) } + ["\r\n"]
        for character in characters {
            let kind = CharacterKind(character)
            #expect(kind.isWhitespace == character.isWhitespace, "\(character.unicodeScalars.map(\.value))")
            #expect(kind.isDigit == character.isNumber, "\(character.unicodeScalars.map(\.value))")
            #expect(kind.isLetterOrDigit == (character.isLetter || character.isNumber), "\(character.unicodeScalars.map(\.value))")
        }
    }

    @Test("an empty transcript counts nothing")
    func empty() throws {
        let stats = try TranscriptTextStats.compute(segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "  ")])
        var expected = TranscriptTextStats()
        expected.segmentWordCounts = [0]
        #expect(stats == expected)
    }

    @Test("a cancelled task stops the walk")
    func cancellation() async {
        let segments = (0..<1000).map { TranscriptSegment(id: $0, start: 0, end: 1, text: "um hello there") }
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try TranscriptTextStats.compute(segments: segments)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
