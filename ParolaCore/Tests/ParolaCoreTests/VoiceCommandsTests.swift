import Foundation
import Testing
@testable import ParolaCore
@testable import ParolaDictation

@Suite("Voice commands")
struct VoiceCommandsTests {
    @Test(
        "applies command",
        arguments: [
            (name: "english period", input: "hello period", language: "en", expected: "hello."),
            (name: "english comma", input: "hello comma world", language: "en", expected: "hello, world"),
            (name: "english question mark", input: "how are you question mark", language: "en", expected: "how are you?"),
            (name: "english new line", input: "first paragraph new line second paragraph", language: "en", expected: "first paragraph\nsecond paragraph"),
            (name: "english new paragraph", input: "end new paragraph start", language: "en", expected: "end\n\nstart"),
            (name: "uppercase command", input: "hello PERIOD", language: "en", expected: "hello."),
            (name: "mixed case command", input: "hello Comma world", language: "en", expected: "hello, world"),
            (name: "non-command text preserved", input: "plain text with no commands", language: "en", expected: "plain text with no commands"),
            (name: "multiple commands collapse whitespace", input: "a comma b period", language: "en", expected: "a, b."),
            (name: "regional code matches", input: "hello period", language: "en-US", expected: "hello."),
            (name: "italian punto", input: "ciao punto come stai", language: "it", expected: "ciao. come stai"),
            (name: "italian virgola", input: "ciao virgola amico", language: "it", expected: "ciao, amico"),
            (name: "italian a capo", input: "primo a capo secondo", language: "it", expected: "primo\nsecondo"),
            (name: "italian punto e virgola multi-word", input: "uno punto e virgola due", language: "it", expected: "uno; due"),
        ]
    )
    func applyTo(name: String, input: String, language: String, expected: String) {
        #expect(VoiceCommands.applyTo(input, language: language) == expected)
    }

    @Test(
        "commands from another language never fire",
        arguments: [
            (name: "italian noun survives english dictation", input: "il punto \u{00E8} questo", language: "en" as String?, expected: "il punto \u{00E8} questo"),
            (name: "english noun survives italian dictation", input: "use a comma here", language: "it" as String?, expected: "use a comma here"),
            (name: "auto-detect applies none", input: "hello period", language: nil as String?, expected: "hello period"),
            (name: "unsupported language applies none", input: "hallo period punkt", language: "de" as String?, expected: "hallo period punkt"),
        ]
    )
    func languageGate(name: String, input: String, language: String?, expected: String) {
        #expect(VoiceCommands.applyTo(input, language: language) == expected)
    }
}
