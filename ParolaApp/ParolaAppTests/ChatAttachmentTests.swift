import Foundation
import Testing
@testable import Parola

@Suite("Chat attachment formatter")
struct ChatAttachmentTests {
    @Test("attaches content under a header with the filename")
    func basicAttachment() {
        let out = ChatAttachment.attach(
            input: "what does this say?",
            filename: "notes.md",
            content: "# Notes\n\nHello there."
        )
        #expect(out.contains("notes.md"))
        #expect(out.contains("Hello there"))
        #expect(out.contains("what does this say?"))
    }

    @Test("appends to non-empty input with a blank line separator")
    func preservesExistingInput() {
        let out = ChatAttachment.attach(
            input: "summarize",
            filename: "a.txt",
            content: "body"
        )
        #expect(out.contains("summarize"))
        let lines = out.split(separator: "\n").map(String.init)
        #expect(lines.contains("summarize"))
    }

    @Test("empty input still produces a context block")
    func emptyInput() {
        let out = ChatAttachment.attach(input: "", filename: "x.txt", content: "body")
        #expect(out.contains("x.txt"))
        #expect(out.contains("body"))
    }

    @Test("trims trailing whitespace from content")
    func trimsContent() {
        let out = ChatAttachment.attach(input: "", filename: "x.txt", content: "body\n\n\n")
        #expect(!out.hasSuffix("\n\n\n"))
    }

    @Test("truncates very long content with a footer note")
    func truncatesLong() {
        let long = String(repeating: "a", count: 12_000)
        let out = ChatAttachment.attach(input: "", filename: "big.txt", content: long, maxCharacters: 4_000)
        #expect(out.count < 5_000)
        #expect(out.contains("truncated"))
    }
}
