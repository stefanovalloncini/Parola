import Foundation
import Testing
import ParolaCore
@testable import Parola

@MainActor
@Suite("Summary body empty state")
struct SummaryBodyTests {
    @Test("empty text and no chapters is empty so the placeholder shows")
    func emptySummaryIsEmpty() {
        #expect(SummaryBody.isEmpty(Summary(text: "", chapters: [])))
    }

    @Test("whitespace-only text and no chapters is empty")
    func whitespaceOnlyIsEmpty() {
        #expect(SummaryBody.isEmpty(Summary(text: "   \n\t ", chapters: [])))
    }

    @Test("text present is not empty")
    func textIsNotEmpty() {
        #expect(!SummaryBody.isEmpty(Summary(text: "A short overview.", chapters: [])))
    }

    @Test("chapters present is not empty even without text")
    func chaptersOnlyIsNotEmpty() {
        #expect(!SummaryBody.isEmpty(Summary(text: "", chapters: [Chapter(title: "Intro", start: 0)])))
    }

    @Test("whitespace text with chapters is not empty")
    func whitespaceTextWithChaptersIsNotEmpty() {
        #expect(!SummaryBody.isEmpty(Summary(text: "  ", chapters: [Chapter(title: "Intro", start: 0)])))
    }
}
