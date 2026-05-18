import Foundation
import Testing
@testable import ParolaCore

@Suite("Voice commands")
struct VoiceCommandsTests {
    @Test("replaces standalone period command with a period")
    func period() {
        #expect(VoiceCommands.applyTo("hello period") == "hello.")
    }

    @Test("replaces comma command")
    func comma() {
        #expect(VoiceCommands.applyTo("hello comma world") == "hello, world")
    }

    @Test("question mark command")
    func questionMark() {
        #expect(VoiceCommands.applyTo("how are you question mark") == "how are you?")
    }

    @Test("new line command becomes a literal newline")
    func newLine() {
        let out = VoiceCommands.applyTo("first paragraph new line second paragraph")
        #expect(out == "first paragraph\nsecond paragraph")
    }

    @Test("new paragraph command becomes double newline")
    func newParagraph() {
        let out = VoiceCommands.applyTo("end new paragraph start")
        #expect(out == "end\n\nstart")
    }

    @Test("commands are case-insensitive")
    func caseInsensitive() {
        #expect(VoiceCommands.applyTo("hello PERIOD") == "hello.")
        #expect(VoiceCommands.applyTo("hello Comma world") == "hello, world")
    }

    @Test("non-command text is preserved")
    func nonCommand() {
        #expect(VoiceCommands.applyTo("plain text with no commands") == "plain text with no commands")
    }

    @Test("multiple commands collapse adjacent whitespace")
    func multipleCommands() {
        #expect(VoiceCommands.applyTo("a comma b period") == "a, b.")
    }

    @Test("italian punto becomes a period")
    func italianPeriod() {
        #expect(VoiceCommands.applyTo("ciao punto come stai") == "ciao. come stai")
    }

    @Test("italian virgola becomes a comma")
    func italianComma() {
        #expect(VoiceCommands.applyTo("ciao virgola amico") == "ciao, amico")
    }

    @Test("italian a capo becomes a newline")
    func italianNewLine() {
        let out = VoiceCommands.applyTo("primo a capo secondo")
        #expect(out == "primo\nsecondo")
    }

    @Test("italian punto e virgola is matched as a multi-word phrase")
    func italianSemicolon() {
        let out = VoiceCommands.applyTo("uno punto e virgola due")
        #expect(out == "uno; due")
    }
}
