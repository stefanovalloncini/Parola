import Testing
@testable import Parola

@MainActor
@Suite("Chat sheet send gate")
struct ChatSheetComposerTests {
    @Test("a real prompt enables send")
    func realPromptEnables() {
        #expect(ChatSheet.isSendDisabled(input: "What is this about?", isSending: false) == false)
    }

    @Test("empty input disables send")
    func emptyDisables() {
        #expect(ChatSheet.isSendDisabled(input: "", isSending: false) == true)
    }

    @Test("spaces-only input disables send")
    func spacesDisable() {
        #expect(ChatSheet.isSendDisabled(input: "   ", isSending: false) == true)
    }

    @Test("newline-only input disables send")
    func newlinesDisable() {
        #expect(ChatSheet.isSendDisabled(input: "\n\n", isSending: false) == true)
    }

    @Test("mixed whitespace and newlines disable send")
    func mixedWhitespaceDisables() {
        #expect(ChatSheet.isSendDisabled(input: " \n \t\n", isSending: false) == true)
    }

    @Test("a send already in flight disables send")
    func sendingDisables() {
        #expect(ChatSheet.isSendDisabled(input: "follow up question", isSending: true) == true)
    }
}
