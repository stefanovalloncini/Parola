import Foundation
import Testing
@testable import ParolaCore

struct StubClipboard: ClipboardReader {
    let value: String?
    func currentText() -> String? { value }
}

@Suite("SnippetExpander")
struct SnippetExpanderTests {
    @Test("replaces a trigger with its replacement on word boundaries")
    func wordBoundedReplace() async {
        let expander = SnippetExpander(snippets: [
            Snippet(trigger: "my email", replacement: "stefano@example.com")
        ])
        let out = await expander.process("Send him my email please")
        #expect(out == "Send him stefano@example.com please")
    }

    @Test("does not replace substring matches across word boundaries")
    func noSubstringMatch() async {
        let expander = SnippetExpander(snippets: [
            Snippet(trigger: "cat", replacement: "🐈")
        ])
        let out = await expander.process("a catalog of cats and one cat")
        #expect(out == "a catalog of cats and one 🐈")
    }

    @Test("is case-insensitive")
    func caseInsensitive() async {
        let expander = SnippetExpander(snippets: [
            Snippet(trigger: "my email", replacement: "stefano@example.com")
        ])
        let out = await expander.process("Send My Email please")
        #expect(out == "Send stefano@example.com please")
    }

    @Test("ignores disabled snippets")
    func disabledIgnored() async {
        let expander = SnippetExpander(snippets: [
            Snippet(trigger: "my email", replacement: "stefano@example.com", enabled: false)
        ])
        let out = await expander.process("Send him my email please")
        #expect(out == "Send him my email please")
    }

    @Test("expands {{ISODATE}} placeholder")
    func isoDatePlaceholder() async {
        let fixed = Date(timeIntervalSince1970: 1_715_000_000)
        let expander = SnippetExpander(
            snippets: [Snippet(trigger: "today", replacement: "{{ISODATE}}")],
            now: { fixed }
        )
        let out = await expander.process("Schedule for today")
        #expect(out == "Schedule for 2024-05-06")
    }

    @Test("expands {{CLIPBOARD}} placeholder")
    func clipboardPlaceholder() async {
        let expander = SnippetExpander(
            snippets: [Snippet(trigger: "paste", replacement: "{{CLIPBOARD}}")],
            clipboard: StubClipboard(value: "hello world")
        )
        let out = await expander.process("Just paste here")
        #expect(out == "Just hello world here")
    }

    @Test("CompositePostProcessor chains expanders")
    func compositeChains() async {
        let first = SnippetExpander(snippets: [Snippet(trigger: "me", replacement: "Stefano")])
        let second = SnippetExpander(snippets: [Snippet(trigger: "Stefano", replacement: "S.")])
        let composite = CompositePostProcessor([first, second])
        let out = await composite.process("hello me")
        #expect(out == "hello S.")
    }
}
