import Foundation
import Testing
@testable import ParolaCore
@testable import ParolaDictation

@Suite("Voice commands")
struct VoiceCommandsTests {
    @Test(
        "applies command",
        arguments: [
            (name: "english period", input: "hello period", expected: "hello."),
            (name: "english comma", input: "hello comma world", expected: "hello, world"),
            (name: "english question mark", input: "how are you question mark", expected: "how are you?"),
            (name: "english new line", input: "first paragraph new line second paragraph", expected: "first paragraph\nsecond paragraph"),
            (name: "english new paragraph", input: "end new paragraph start", expected: "end\n\nstart"),
            (name: "uppercase command", input: "hello PERIOD", expected: "hello."),
            (name: "mixed case command", input: "hello Comma world", expected: "hello, world"),
            (name: "non-command text preserved", input: "plain text with no commands", expected: "plain text with no commands"),
            (name: "multiple commands collapse whitespace", input: "a comma b period", expected: "a, b."),
            (name: "italian punto", input: "ciao punto come stai", expected: "ciao. come stai"),
            (name: "italian virgola", input: "ciao virgola amico", expected: "ciao, amico"),
            (name: "italian a capo", input: "primo a capo secondo", expected: "primo\nsecondo"),
            (name: "italian punto e virgola multi-word", input: "uno punto e virgola due", expected: "uno; due"),
        ]
    )
    func applyTo(name: String, input: String, expected: String) {
        #expect(VoiceCommands.applyTo(input) == expected)
    }
}
