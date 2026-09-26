import Foundation
import Testing
@testable import ParolaCore

@Suite("Find & replace")
struct SearchTests {
    private func sample() -> Transcript {
        Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello world."),
                TranscriptSegment(id: 1, start: 1, end: 2, text: "Hello again, world."),
                TranscriptSegment(id: 2, start: 2, end: 3, text: "Goodbye world!"),
            ],
            language: "en",
            modelName: "tiny"
        )
    }

    @Test("empty query returns no matches")
    func emptyQuery() {
        #expect(sample().findMatches("").isEmpty)
    }

    @Test("case-insensitive find returns every occurrence")
    func findAll() {
        let matches = sample().findMatches("hello")
        #expect(matches.count == 2)
        #expect(matches[0].segmentID == 0)
        #expect(matches[1].segmentID == 1)
    }

    @Test("case-sensitive find respects case")
    func caseSensitive() {
        #expect(sample().findMatches("hello", caseSensitive: true).isEmpty)
        #expect(sample().findMatches("Hello", caseSensitive: true).count == 2)
    }

    @Test("multiple matches in one segment")
    func multipleInOne() {
        let t = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "abcabcabc")],
            language: "en",
            modelName: "tiny"
        )
        let matches = t.findMatches("abc")
        #expect(matches.count == 3)
        #expect(matches.map(\.range.lowerBound) == [0, 3, 6])
    }

    @Test("replace single match leaves other segments alone")
    func replaceSingle() {
        let matches = sample().findMatches("Hello")
        let updated = sample().applying(replacement: "Hi", to: matches[0])
        #expect(updated.segments[0].text == "Hi world.")
        #expect(updated.segments[1].text == "Hello again, world.")
        #expect(updated.segments[2].text == "Goodbye world!")
    }

    @Test("replaceAll hits every occurrence")
    func replaceAll() {
        let updated = sample().replacingAll("world", with: "earth")
        #expect(updated.segments[0].text == "Hello earth.")
        #expect(updated.segments[1].text == "Hello again, earth.")
        #expect(updated.segments[2].text == "Goodbye earth!")
    }

    @Test("replaceAll with empty query is a no-op")
    func replaceAllEmpty() {
        let t = sample()
        #expect(t.replacingAll("", with: "x").segments.map(\.text) == t.segments.map(\.text))
    }

    @Test("replace with a negative-offset match range leaves the text unchanged")
    func replaceNegativeRange() {
        let t = sample()
        let updated = t.applying(replacement: "X", to: TranscriptMatch(segmentID: 0, range: -1..<2))
        #expect(updated.segments[0].text == "Hello world.")
    }

    @Test("works with accented characters")
    func unicode() {
        let t = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "Caffè caffè CAFFÈ")],
            language: "it",
            modelName: "tiny"
        )
        #expect(t.findMatches("caffè").count == 3)
        #expect(t.findMatches("caffè", caseSensitive: true).count == 1)
    }

    private func wordTimed() -> Transcript {
        Transcript(
            segments: [
                TranscriptSegment(
                    id: 0, start: 0, end: 1, text: "Hello world.",
                    words: [
                        WordTiming(id: "0-0", word: "Hello", start: 0, end: 0.5, probability: 1),
                        WordTiming(id: "0-1", word: "world.", start: 0.5, end: 1, probability: 1),
                    ]
                ),
                TranscriptSegment(
                    id: 1, start: 1, end: 2, text: "Goodbye world.",
                    words: [
                        WordTiming(id: "1-0", word: "Goodbye", start: 1, end: 1.5, probability: 1),
                        WordTiming(id: "1-1", word: "world.", start: 1.5, end: 2, probability: 1),
                    ]
                ),
            ],
            language: "en",
            modelName: "tiny"
        )
    }

    @Test("replacing a match drops the edited segment's stale word timings, leaving siblings intact")
    func applyingDropsWords() {
        let t = wordTimed()
        let match = t.findMatches("Hello")[0]
        let updated = t.applying(replacement: "Hi", to: match)
        #expect(updated.segments[0].text == "Hi world.")
        #expect(updated.segments[0].words == nil)
        #expect(updated.segments[1].words != nil)
    }

    @Test("a no-op replacement keeps the segment's word timings")
    func applyingNoChangeKeepsWords() {
        let t = wordTimed()
        let updated = t.applying(replacement: "X", to: TranscriptMatch(segmentID: 0, range: -1..<2))
        #expect(updated.segments[0].text == "Hello world.")
        #expect(updated.segments[0].words != nil)
    }

    @Test("replaceAll drops word timings only on segments whose text changed")
    func replacingAllDropsWordsWhereChanged() {
        let t = wordTimed()
        let updated = t.replacingAll("Goodbye", with: "Farewell")
        #expect(updated.segments[0].text == "Hello world.")
        #expect(updated.segments[0].words != nil)
        #expect(updated.segments[1].text == "Farewell world.")
        #expect(updated.segments[1].words == nil)
    }

    /// The String-overlay loop `findMatches` used before it moved to NSString.
    private static func referenceMatches(_ transcript: Transcript, _ query: String, caseSensitive: Bool) -> [TranscriptMatch] {
        guard !query.isEmpty else { return [] }
        var out: [TranscriptMatch] = []
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        for segment in transcript.segments {
            var searchStart = segment.text.startIndex
            while searchStart < segment.text.endIndex,
                  let r = segment.text.range(of: query, options: options, range: searchStart..<segment.text.endIndex) {
                let lo = segment.text.utf16.distance(from: segment.text.startIndex, to: r.lowerBound)
                let hi = segment.text.utf16.distance(from: segment.text.startIndex, to: r.upperBound)
                out.append(TranscriptMatch(segmentID: segment.id, range: lo..<hi))
                searchStart = r.upperBound
            }
        }
        return out
    }

    @Test("matches are the ones the String search found, over accents, emoji and case folding")
    func matchesAgreeWithTheStringSearch() {
        let texts = [
            "Caffè caffè CAFFÈ, perché è così.",
            "Cafe\u{301} decomposed next to café composed.",
            "👩‍👩‍👧 family 👩‍👩‍👧 and 👍🏽 thumbs 🇮🇹 flag 🇮🇹",
            "Straße STRASSE strasse ß SS",
            "İstanbul istanbul ISTANBUL ı I",
            "ΣΟΦΟΣ σοφος σοφoς ΣΊΣΥΦΟΣ",
            "ﬁle file FILE ﬁ fi",
            "aaaa aaa naïve NAÏVE naive",
            "one\r\ntwo\nthree\r four",
            "",
            "   ",
        ]
        let transcript = Transcript(
            segments: texts.enumerated().map { TranscriptSegment(id: $0.offset * 3, start: Double($0.offset), end: Double($0.offset) + 1, text: $0.element) },
            language: "it",
            modelName: "tiny"
        )
        let queries = [
            "caffè", "CAFFÈ", "é", "e", "café", "👩‍👩‍👧", "👍", "🏽", "🇮🇹", "ss", "SS", "strasse",
            "i", "İ", "istanbul", "σοφος", "Σ", "ς", "fi", "file", "aa", "a", "ï", "naive", " ", "zzz",
            "\n", "\r", "\r\n", "one\r\ntwo",
        ]
        for query in queries {
            for caseSensitive in [false, true] {
                #expect(
                    transcript.findMatches(query, caseSensitive: caseSensitive)
                        == Self.referenceMatches(transcript, query, caseSensitive: caseSensitive),
                    "query \(query) caseSensitive \(caseSensitive)"
                )
            }
        }
    }

    /// The String search matched "St" for "ß" and "ff" for "ﬁ", where Replace All disagreed.
    @Test("matches are the spans Replace All rewrites where the String search disagreed with it")
    func matchesAgreeWithReplaceAll() {
        let transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: "Straße STRASSE ß così"),
                TranscriptSegment(id: 1, start: 1, end: 2, text: "Caffè ﬁle file"),
                TranscriptSegment(id: 2, start: 2, end: 3, text: "👍🏽 thumbs 👍"),
            ],
            language: "it",
            modelName: "tiny"
        )
        #expect(transcript.findMatches("ß").map(\.range) == [4..<5, 11..<13, 15..<16])
        #expect(transcript.replacingAll("ß", with: "#").segments[0].text == "Stra#e STRA#E # così")
        #expect(transcript.findMatches("ﬁ").map(\.range) == [6..<7, 10..<12])
        #expect(transcript.replacingAll("ﬁ", with: "#").segments[1].text == "Caffè #le #le")
        #expect(transcript.findMatches("🏽").isEmpty)
        #expect(transcript.replacingAll("🏽", with: "#").segments[2].text == "👍🏽 thumbs 👍")
        #expect(!Transcript.containsMatch("🏽", in: transcript.segments))
        #expect(Transcript.containsMatch("ß", in: transcript.segments))
    }

    @Test("a match never cuts a character, so a single Replace applies every one Find offers")
    func everyMatchIsReplaceable() {
        let transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: "👍🏽 ok 👍 🇮🇹🇮🇹 👩‍👩‍👧 cafe\u{301} café"),
                TranscriptSegment(id: 1, start: 1, end: 2, text: "one\r\ntwo\nthree Straße ß"),
            ],
            language: "it",
            modelName: "tiny"
        )
        for query in ["🏽", "👍", "🇮", "🇮🇹", "👩", "‍", "\u{301}", "e", "é", "\n", "\r", "\r\n", "ß", "ss", "o"] {
            let matches = transcript.findMatches(query)
            for match in matches {
                #expect(transcript.applying(replacement: "#", to: match) != transcript, "\(query) at \(match.range)")
            }
            let rewritten = transcript.replacingAll(query, with: "#")
            let replacedSegments = Set(matches.map(\.segmentID))
            for (before, after) in zip(transcript.segments, rewritten.segments) {
                #expect((before.text != after.text) == replacedSegments.contains(before.id), "\(query) in \(before.id)")
            }
        }
        #expect(transcript.findMatches("\n").map(\.range) == [8..<9])
    }

    @Test("Replace All rewrites what it always did wherever the matches are whole characters")
    func replaceAllKeepsItsOutput() {
        let texts = ["Hello hello HELLO", "Caffè caffè CAFFÈ perché", "Straße STRASSE strasse ß", "ﬁle file FILE", "👩‍👩‍👧 👍 🇮🇹", "abcabcabc", ""]
        let transcript = Transcript(
            segments: texts.enumerated().map { TranscriptSegment(id: $0.offset, start: 0, end: 1, text: $0.element) },
            language: "it",
            modelName: "tiny"
        )
        for query in ["hello", "HELLO", "caffè", "è", "ß", "ss", "ﬁ", "fi", "👍", "🇮🇹", "abc", "a", " ", "zzz"] {
            for caseSensitive in [false, true] {
                let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
                let expected = texts.map { $0.replacingOccurrences(of: query, with: "[$0]", options: options) }
                let actual = transcript.replacingAll(query, with: "[$0]", caseSensitive: caseSensitive).segments.map(\.text)
                #expect(actual == expected, "\(query) caseSensitive \(caseSensitive)")
            }
        }
    }
}
