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

    @Test("Italian dictation keeps the lone article i lowercase")
    func italianKeepsArticleI() async {
        let out = await makeProcessor(language: "it").process("compra i libri")
        #expect(out == "Compra i libri")
    }

    @Test("English dictation capitalizes the lone pronoun i")
    func englishCapitalizesPronounI() async {
        let out = await makeProcessor(language: "en").process("compra i libri")
        #expect(out == "Compra I libri")
    }

    @Test("Unknown language defaults to English capitalization")
    func unknownLanguageDefaultsToEnglish() async {
        let out = await makeProcessor(language: nil).process("compra i libri")
        #expect(out == "Compra I libri")
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
}
