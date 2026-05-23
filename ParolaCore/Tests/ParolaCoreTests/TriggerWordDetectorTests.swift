import Foundation
import Testing
@testable import ParolaCore
@testable import ParolaDictation

@Suite("Trigger word detector")
struct TriggerWordDetectorTests {
    private let summary = Prompt(
        name: "Summary",
        instructions: "Summarise.",
        triggerWords: ["summary"]
    )
    private let concise = Prompt(
        name: "Concise",
        instructions: "Tighten.",
        triggerWords: ["concise"]
    )
    private let codeComment = Prompt(
        name: "Code comment",
        instructions: "Comment.",
        triggerWords: ["code comment"]
    )

    @Test("leading trigger word with comma")
    func leadingComma() {
        let det = TriggerWordDetector()
        let m = det.detect("summary, my notes", against: [summary])
        #expect(m?.promptID == summary.id)
        #expect(m?.cleanedText == "my notes")
    }

    @Test("leading trigger word with period")
    func leadingPeriod() {
        let det = TriggerWordDetector()
        let m = det.detect("summary. my notes", against: [summary])
        #expect(m?.promptID == summary.id)
        #expect(m?.cleanedText == "my notes")
    }

    @Test("leading trigger word with colon and space")
    func leadingColon() {
        let det = TriggerWordDetector()
        let m = det.detect("summary : my notes", against: [summary])
        #expect(m?.cleanedText == "my notes")
    }

    @Test("leading trigger word, no punctuation")
    func leadingPlain() {
        let det = TriggerWordDetector()
        let m = det.detect("summary my notes", against: [summary])
        #expect(m?.promptID == summary.id)
        #expect(m?.cleanedText == "my notes")
    }

    @Test("trailing trigger word")
    func trailing() {
        let det = TriggerWordDetector()
        let m = det.detect("make this short, concise", against: [concise])
        #expect(m?.promptID == concise.id)
        #expect(m?.cleanedText == "make this short")
    }

    @Test("trailing trigger word with period")
    func trailingPeriod() {
        let det = TriggerWordDetector()
        let m = det.detect("make this short. concise.", against: [concise])
        #expect(m?.cleanedText == "make this short")
    }

    @Test("case insensitive")
    func caseInsensitive() {
        let det = TriggerWordDetector()
        let m = det.detect("Summary, my notes", against: [summary])
        #expect(m?.promptID == summary.id)
        #expect(m?.cleanedText == "my notes")
    }

    @Test("mid-sentence is not a match")
    func midSentenceIgnored() {
        let det = TriggerWordDetector()
        let m = det.detect("the summary section is short", against: [summary])
        #expect(m == nil)
    }

    @Test("no trigger words means no match")
    func noTriggers() {
        let det = TriggerWordDetector()
        let bare = Prompt(name: "Bare", instructions: "x", triggerWords: [])
        let m = det.detect("summary, my notes", against: [bare])
        #expect(m == nil)
    }

    @Test("first prompt wins on multiple matches")
    func firstWins() {
        let det = TriggerWordDetector()
        let other = Prompt(name: "Other", instructions: "x", triggerWords: ["summary"])
        let m = det.detect("summary, hello", against: [summary, other])
        #expect(m?.promptID == summary.id)
    }

    @Test("empty input returns nil")
    func emptyInput() {
        let det = TriggerWordDetector()
        let m = det.detect("", against: [summary])
        #expect(m == nil)
    }

    @Test("whitespace-only input returns nil")
    func whitespaceOnly() {
        let det = TriggerWordDetector()
        let m = det.detect("   \n  ", against: [summary])
        #expect(m == nil)
    }

    @Test("multi-word trigger phrase matches")
    func multiWordTrigger() {
        let det = TriggerWordDetector()
        let m = det.detect("code comment, fix the parser", against: [codeComment])
        #expect(m?.promptID == codeComment.id)
        #expect(m?.cleanedText == "fix the parser")
    }

    @Test("exact match with only the trigger word yields empty cleaned text")
    func onlyTrigger() {
        let det = TriggerWordDetector()
        let m = det.detect("summary", against: [summary])
        #expect(m?.promptID == summary.id)
        #expect(m?.cleanedText == "")
    }

    @Test("prefix word that is not a whole trigger does not match")
    func wholeWordOnly() {
        let det = TriggerWordDetector()
        let m = det.detect("summarytown is far", against: [summary])
        #expect(m == nil)
    }
}
