import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaDictation

@Suite("Prompt dictation processor")
struct PromptDictationProcessorTests {
    private func makeProcessor(language: String?) -> PromptDictationProcessor {
        PromptDictationProcessor(defaultPrompt: nil, overrides: [:], language: language)
    }

    @Test("voice mode returns the transcript verbatim")
    func voiceModeVerbatim() async {
        let out = await makeProcessor(language: "it").process("compra i libri punto")
        #expect(out == "compra i libri punto")
        let en = await makeProcessor(language: "en").process("check example.com and i said period")
        #expect(en == "check example.com and i said period")
        let auto = await makeProcessor(language: nil).process("il punto \u{00E8} questo")
        #expect(auto == "il punto \u{00E8} questo")
    }

    @Test("the rewrite step gates commands and pronouns by language")
    func rewriteStepLanguageGating() {
        #expect(PromptDictationProcessor.rewritten("compra i libri", language: "it") == "Compra i libri")
        #expect(PromptDictationProcessor.rewritten("i said period", language: "en") == "I said.")
        #expect(PromptDictationProcessor.rewritten("hello period", language: nil) == "Hello period")
    }

    private func makeProcessor(
        overrides: [String: [DictationOverrideEntry]],
        url: URL? = nil
    ) -> PromptDictationProcessor {
        PromptDictationProcessor(
            defaultPrompt: nil,
            overrides: overrides,
            urlResolver: { _ in url }
        )
    }

    @Test("a trigger-word-only utterance inserts nothing")
    func triggerOnlyUtteranceInsertsNothing() async {
        var assistant = Prompt(name: "Assistant", instructions: "rewrite")
        assistant.triggerWords = ["ehi parola"]
        let proc = PromptDictationProcessor(
            defaultPrompt: nil,
            overrides: [:],
            triggerPrompts: [assistant],
            language: "it",
            cleanupRunner: { _, _ in "CHATTER" }
        )
        let out = await proc.process("ehi parola")
        #expect(out == "", "no content after the trigger word means nothing to clean up or insert")
    }

    @Test("a wedged cleanup model can't hold the utterance past the timeout")
    func cleanupTimeoutFallsBackToInput() async {
        let proc = PromptDictationProcessor(
            defaultPrompt: Prompt(name: "Cleanup", instructions: "c"),
            overrides: [:],
            language: "en",
            cleanupTimeout: .milliseconds(50),
            cleanupRunner: { _, _ in
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                        continuation.resume(returning: ())
                    }
                }
                return "LATE"
            }
        )
        let out = await proc.process("hello there")
        #expect(out == "Hello there", "the rewritten input wins when the model misses the deadline")
    }

    private actor ResolverSpy {
        private(set) var called = false
        func mark() { called = true }
    }

    @Test("selectOverridePrompt skips URL resolution when no rule has a pattern")
    func selectSkipsResolverWithoutURLRules() async {
        let spy = ResolverSpy()
        let mail = Prompt(name: "Mail", instructions: "m")
        let proc = PromptDictationProcessor(
            defaultPrompt: nil,
            overrides: ["com.apple.mail": [DictationOverrideEntry(prompt: mail, urlPattern: nil)]],
            urlResolver: { _ in
                await spy.mark()
                return nil
            }
        )
        let chosen = await proc.selectOverridePrompt(bundleID: "com.apple.mail")
        #expect(chosen?.id == mail.id)
        #expect(await spy.called == false, "no URL rule for the bundle, so the browser must not be queried")
    }

    @Test("selectOverridePrompt returns nil when the bundle has no override")
    func selectNoOverrideForBundle() async {
        let mail = Prompt(name: "Mail", instructions: "m")
        let proc = makeProcessor(overrides: ["com.apple.mail": [DictationOverrideEntry(prompt: mail, urlPattern: nil)]])
        let chosen = await proc.selectOverridePrompt(bundleID: "com.apple.Safari")
        #expect(chosen == nil)
    }

    @Test("selectOverridePrompt returns nil for a nil bundleID")
    func selectNilBundle() async {
        let mail = Prompt(name: "Mail", instructions: "m")
        let proc = makeProcessor(overrides: ["com.apple.mail": [DictationOverrideEntry(prompt: mail, urlPattern: nil)]])
        let chosen = await proc.selectOverridePrompt(bundleID: nil)
        #expect(chosen == nil)
    }

    @Test("selectOverridePrompt returns the bundle default when there is no URL rule")
    func selectDefaultNoURLRule() async {
        let def = Prompt(name: "Default", instructions: "d")
        let proc = makeProcessor(
            overrides: ["com.apple.mail": [DictationOverrideEntry(prompt: def, urlPattern: nil)]],
            url: URL(string: "https://anything.example.com")
        )
        let chosen = await proc.selectOverridePrompt(bundleID: "com.apple.mail")
        #expect(chosen?.id == def.id)
    }

    @Test("selectOverridePrompt prefers a URL-matching rule over the bundle default")
    func selectURLMatchOverDefault() async {
        let def = Prompt(name: "Default", instructions: "d")
        let gmail = Prompt(name: "Gmail", instructions: "g")
        let proc = makeProcessor(
            overrides: ["com.google.Chrome": [
                DictationOverrideEntry(prompt: def, urlPattern: nil),
                DictationOverrideEntry(prompt: gmail, urlPattern: "gmail.com"),
            ]],
            url: URL(string: "https://mail.gmail.com/u/0/")
        )
        let chosen = await proc.selectOverridePrompt(bundleID: "com.google.Chrome")
        #expect(chosen?.id == gmail.id)
    }

    @Test("selectOverridePrompt falls back to the default when the URL does not match")
    func selectFallbackWhenURLMismatch() async {
        let def = Prompt(name: "Default", instructions: "d")
        let gmail = Prompt(name: "Gmail", instructions: "g")
        let proc = makeProcessor(
            overrides: ["com.google.Chrome": [
                DictationOverrideEntry(prompt: def, urlPattern: nil),
                DictationOverrideEntry(prompt: gmail, urlPattern: "gmail.com"),
            ]],
            url: URL(string: "https://news.ycombinator.com")
        )
        let chosen = await proc.selectOverridePrompt(bundleID: "com.google.Chrome")
        #expect(chosen?.id == def.id)
    }

    @Test("selectOverridePrompt falls back to the default when no URL can be resolved")
    func selectFallbackWhenNoURL() async {
        let def = Prompt(name: "Default", instructions: "d")
        let gmail = Prompt(name: "Gmail", instructions: "g")
        let proc = makeProcessor(
            overrides: ["com.google.Chrome": [
                DictationOverrideEntry(prompt: def, urlPattern: nil),
                DictationOverrideEntry(prompt: gmail, urlPattern: "gmail.com"),
            ]],
            url: nil
        )
        let chosen = await proc.selectOverridePrompt(bundleID: "com.google.Chrome")
        #expect(chosen?.id == def.id)
    }

    @Test("selectOverridePrompt matches the URL host case-insensitively")
    func selectURLMatchCaseInsensitive() async {
        let def = Prompt(name: "Default", instructions: "d")
        let gmail = Prompt(name: "Gmail", instructions: "g")
        let proc = makeProcessor(
            overrides: ["com.google.Chrome": [
                DictationOverrideEntry(prompt: def, urlPattern: nil),
                DictationOverrideEntry(prompt: gmail, urlPattern: "GMAIL.com"),
            ]],
            url: URL(string: "https://mail.gmail.com/")
        )
        let chosen = await proc.selectOverridePrompt(bundleID: "com.google.Chrome")
        #expect(chosen?.id == gmail.id)
    }

    @Test("selectOverridePrompt returns the first matching URL rule when several match")
    func selectFirstURLMatch() async {
        let first = Prompt(name: "First", instructions: "1")
        let second = Prompt(name: "Second", instructions: "2")
        let proc = makeProcessor(
            overrides: ["com.google.Chrome": [
                DictationOverrideEntry(prompt: first, urlPattern: "github.com"),
                DictationOverrideEntry(prompt: second, urlPattern: ".com"),
            ]],
            url: URL(string: "https://github.com/foo/bar")
        )
        let chosen = await proc.selectOverridePrompt(bundleID: "com.google.Chrome")
        #expect(chosen?.id == first.id)
    }

    @Test("selectOverridePrompt returns nil when the only rule is URL-scoped and nothing matches")
    func selectNilWhenOnlyURLRuleAndNoMatch() async {
        let gmail = Prompt(name: "Gmail", instructions: "g")
        let proc = makeProcessor(
            overrides: ["com.google.Chrome": [DictationOverrideEntry(prompt: gmail, urlPattern: "gmail.com")]],
            url: URL(string: "https://example.com")
        )
        let chosen = await proc.selectOverridePrompt(bundleID: "com.google.Chrome")
        #expect(chosen == nil)
    }

    private func contextProc() -> PromptDictationProcessor {
        PromptDictationProcessor(defaultPrompt: nil, overrides: [:])
    }

    @Test("contextualizing prepends present context blocks to a system-instruction prompt")
    func contextualizingInjectsContext() {
        let prompt = Prompt(name: "Cleanup", instructions: "Fix the grammar.")
        let context = DictationContext(selection: "Acme Corp", clipboard: "kubectl", screen: nil)
        let situated = contextProc().contextualizing(prompt, with: "Mail", context: context)
        #expect(situated.instructions.contains("Context: the user is dictating into Mail."))
        #expect(situated.instructions.contains("<CURRENTLY_SELECTED_TEXT>Acme Corp</CURRENTLY_SELECTED_TEXT>"))
        #expect(situated.instructions.contains("<CLIPBOARD_CONTEXT>kubectl</CLIPBOARD_CONTEXT>"))
        #expect(situated.instructions.contains("<CURRENT_WINDOW_CONTEXT>") == false)
        #expect(situated.instructions.hasSuffix("Fix the grammar."))
    }

    @Test("contextualizing leaves a verbatim (non-system-instruction) prompt untouched")
    func contextualizingSkipsRawPrompt() {
        var prompt = Prompt(name: "Raw", instructions: "verbatim")
        prompt.useSystemInstructions = false
        let context = DictationContext(selection: "Acme Corp", clipboard: nil, screen: nil)
        let situated = contextProc().contextualizing(prompt, with: "Mail", context: context)
        #expect(situated.instructions == "verbatim")
    }

    @Test("contextualizing with empty context and no app name leaves the instructions unchanged")
    func contextualizingEmptyContext() {
        let prompt = Prompt(name: "Cleanup", instructions: "Fix it.")
        let situated = contextProc().contextualizing(prompt, with: nil, context: .empty)
        #expect(situated.instructions == "Fix it.")
    }
}
