import Foundation
import Testing
@testable import ParolaCore
@testable import ParolaDictation

struct StubClipboard: ClipboardReader {
    let value: String?
    func currentText() -> String? { value }
}

struct StubSelection: SelectionReader {
    let value: String?
    func currentSelection() -> String? { value }
}

struct StubAppContext: AppContextReader {
    let value: String?
    func frontmostAppName() -> String? { value }
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

    @Test("expands a trigger that ends with punctuation")
    func punctuationEndedTrigger() async {
        let expander = SnippetExpander(snippets: [
            Snippet(trigger: "brb!", replacement: "be right back!")
        ])
        let out = await expander.process("ok brb! now")
        #expect(out == "ok be right back! now")
    }

    @Test("expands a symbol-only trigger")
    func symbolTrigger() async {
        let expander = SnippetExpander(snippets: [
            Snippet(trigger: ":)", replacement: "🙂")
        ])
        let out = await expander.process("hi :) there")
        #expect(out == "hi 🙂 there")
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

    @Test("expands {{SELECTION}} from the selection reader")
    func selectionPlaceholder() async {
        let expander = SnippetExpander(
            snippets: [Snippet(trigger: "quote", replacement: "> {{SELECTION}}")],
            selection: StubSelection(value: "hi there")
        )
        let out = await expander.process("Please quote here")
        #expect(out == "Please > hi there here")
    }

    @Test("expands {{APP}} from the app context reader")
    func appPlaceholder() async {
        let expander = SnippetExpander(
            snippets: [Snippet(trigger: "where", replacement: "writing in {{APP}}")],
            appContext: StubAppContext(value: "Notes")
        )
        let out = await expander.process("typed where now")
        #expect(out == "typed writing in Notes now")
    }

    @Test("{{CURSOR}} is replaced with the cursor marker sentinel")
    func cursorPlaceholder() async {
        let expander = SnippetExpander(snippets: [
            Snippet(trigger: "sig", replacement: "Best,\n{{CURSOR}}\nStefano")
        ])
        let out = await expander.process("typed sig here")
        #expect(out.contains(SnippetMarker.cursor))
    }

    @Test("expandAtInsert snippets are skipped at process time")
    func expandAtInsertSkipsDefault() async {
        let snippet = Snippet(trigger: "paste", replacement: "{{CLIPBOARD}}", expandAtInsert: true)
        let expander = SnippetExpander(
            snippets: [snippet],
            clipboard: StubClipboard(value: "at-process")
        )
        let out = await expander.process("now paste me")
        #expect(out == "now paste me")
    }

    @Test("deferredOnly() expands only insert-time snippets")
    func deferredOnlyExpandsInsertTime() async {
        let snippet = Snippet(trigger: "paste", replacement: "{{CLIPBOARD}}", expandAtInsert: true)
        let expander = SnippetExpander(
            snippets: [snippet],
            clipboard: StubClipboard(value: "fresh-paste")
        )
        let deferred = expander.deferredOnly()
        let out = await deferred.process("now paste me")
        #expect(out == "now fresh-paste me")
    }

    @Test("snippet decodes without expandAtInsert field for backward compat")
    func snippetDecodesLegacy() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","trigger":"x","replacement":"y","enabled":true}"#
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(Snippet.self, from: data)
        #expect(decoded.expandAtInsert == false)
        #expect(decoded.trigger == "x")
    }
}
