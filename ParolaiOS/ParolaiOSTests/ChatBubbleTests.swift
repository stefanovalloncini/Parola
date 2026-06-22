import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("Chat bubble display text")
struct ChatBubbleTests {
    @Test("trims surrounding whitespace and newlines")
    func trimsWhitespace() {
        #expect(ChatBubble.displayText("\n\n  Hello there.  \n") == "Hello there.")
    }

    @Test("whitespace-only reply collapses to empty so the placeholder shows")
    func whitespaceOnlyIsEmpty() {
        #expect(ChatBubble.displayText("   \n\t ").isEmpty)
    }

    @Test("keeps internal newlines of a multi-line reply")
    func keepsInternalNewlines() {
        #expect(ChatBubble.displayText("Point one.\nPoint two.") == "Point one.\nPoint two.")
    }

    @Test("keeps already-clean text unchanged")
    func keepsCleanText() {
        #expect(ChatBubble.displayText("Done") == "Done")
    }
}
