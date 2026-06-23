import Testing
@testable import Parola

@MainActor
@Suite("Chat composer send gate")
struct ChatComposerTests {
    @Test("a real prompt enables send")
    func realPromptEnables() {
        #expect(ChatPane.isSendDisabled(input: "What is this about?", isSending: false) == false)
    }

    @Test("empty input disables send")
    func emptyDisables() {
        #expect(ChatPane.isSendDisabled(input: "", isSending: false) == true)
    }

    @Test("spaces-only input disables send")
    func spacesDisable() {
        #expect(ChatPane.isSendDisabled(input: "   ", isSending: false) == true)
    }

    @Test("newline-only input disables send")
    func newlinesDisable() {
        #expect(ChatPane.isSendDisabled(input: "\n\n", isSending: false) == true)
    }

    @Test("mixed whitespace and newlines disable send")
    func mixedWhitespaceDisables() {
        #expect(ChatPane.isSendDisabled(input: " \n \t\n", isSending: false) == true)
    }

    @Test("a send already in flight disables send")
    func sendingDisables() {
        #expect(ChatPane.isSendDisabled(input: "follow up question", isSending: true) == true)
    }
}
