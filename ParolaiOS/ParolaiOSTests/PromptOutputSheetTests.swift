import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("Prompt output sheet display text")
struct PromptOutputSheetTests {
    @Test("trims surrounding whitespace and newlines")
    func trimsWhitespace() {
        #expect(PromptOutputSheet.displayText("\n\n  Summary.  \n") == "Summary.")
    }

    @Test("whitespace-only output collapses to empty so the placeholder shows")
    func whitespaceOnlyIsEmpty() {
        #expect(PromptOutputSheet.displayText("   \n\t ").isEmpty)
    }

    @Test("keeps internal newlines of multi-line output")
    func keepsInternalNewlines() {
        #expect(PromptOutputSheet.displayText("00:00 Intro\n01:30 Topic") == "00:00 Intro\n01:30 Topic")
    }

    @Test("keeps already-clean text unchanged")
    func keepsCleanText() {
        #expect(PromptOutputSheet.displayText("Done") == "Done")
    }
}
