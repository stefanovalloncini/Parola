import Testing
@testable import Parola

@MainActor
@Suite("Chat composer send gate")
struct ChatComposerTests {
    @Test("a real prompt enables send")
    func realPromptEnables() {
        #expect(ChatPane.isSendDisabled(input: "What is this about?", isReplying: false) == false)
    }

    @Test("empty input disables send")
    func emptyDisables() {
        #expect(ChatPane.isSendDisabled(input: "", isReplying: false) == true)
    }

    @Test("spaces-only input disables send")
    func spacesDisable() {
        #expect(ChatPane.isSendDisabled(input: "   ", isReplying: false) == true)
    }

    @Test("newline-only input disables send")
    func newlinesDisable() {
        #expect(ChatPane.isSendDisabled(input: "\n\n", isReplying: false) == true)
    }

    @Test("mixed whitespace and newlines disable send")
    func mixedWhitespaceDisables() {
        #expect(ChatPane.isSendDisabled(input: " \n \t\n", isReplying: false) == true)
    }

    @Test("a reply still streaming disables send")
    func sendingDisables() {
        #expect(ChatPane.isSendDisabled(input: "follow up question", isReplying: true) == true)
    }
}
