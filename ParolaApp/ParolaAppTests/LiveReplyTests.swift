import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("Live chat reply")
struct LiveReplyTests {
    @Test("the first words show at once and later ones wait for the flush interval")
    func flushesAtMostOncePerInterval() {
        let live = LiveReply()
        let id = UUID()
        let t0 = ContinuousClock.now
        live.append("We ", replyID: id, at: t0)
        #expect(live.replyID == id)
        #expect(live.shown == "We ")
        live.append("ship ", replyID: id, at: t0 + .milliseconds(10))
        live.append("on ", replyID: id, at: t0 + .milliseconds(20))
        #expect(live.shown == "We ")
        #expect(live.said == "We ship on ")
        live.append("Fri", replyID: id, at: t0 + LiveReply.flushInterval + .milliseconds(5))
        #expect(live.shown == "We ship on Fri")
        live.end()
    }

    @Test("words held back by the interval still show without another delta")
    func trailingFlushShowsTheNewest() async {
        let live = LiveReply()
        let id = UUID()
        live.append("a", replyID: id)
        live.append("b", replyID: id)
        live.append("c", replyID: id)
        #expect(live.shown == "a")
        await waitUntil { live.shown == "abc" }
        #expect(live.shown == "abc")
        live.end()
    }

    @Test("ending the reply clears it and cancels a pending flush")
    func endClearsEverything() {
        let live = LiveReply()
        let id = UUID()
        live.append("a", replyID: id)
        live.append("b", replyID: id)
        #expect(live.hasPendingFlush)
        live.end()
        #expect(!live.hasPendingFlush)
        #expect(live.replyID == nil)
        #expect(live.said.isEmpty)
        #expect(live.shown.isEmpty)
    }

    @Test("a new reply starts clean, and a turn that was replaced can't end the new one")
    func newReplyStartsClean() {
        let live = LiveReply()
        let first = UUID()
        let second = UUID()
        live.append("old ", replyID: first)
        live.append("words", replyID: first)
        live.append("new", replyID: second)
        #expect(live.said == "new")
        #expect(live.shown == "new")
        live.end(ifHolding: first)
        #expect(live.replyID == second)
        live.end(ifHolding: second)
        #expect(live.replyID == nil)
    }

    @Test("a stopped reply is read from what was said, not from what was last shown")
    func stoppedReadsTheLatestWords() {
        let live = LiveReply()
        let id = UUID()
        live.append("one ", replyID: id)
        live.append("two", replyID: id)
        #expect(live.shown == "one ")
        let turn = ChatPane.LiveTurn(question: ChatMessage(role: .user, text: "q"), replyID: id)
        guard case .keep(let reply) = ChatPane.stoppedTurn(turn, said: live.said) else {
            Issue.record("a reply with words wasn't kept")
            return
        }
        #expect(reply.text == "one two")
        live.end()
    }

    @Test("a question that got no answer leaves the history and returns to an empty composer; over a draft it stays in the history")
    func unansweredQuestionGoesBack() {
        let kept = ChatMessage(role: .user, text: "earlier")
        let question = ChatMessage(role: .user, text: "What was decided?")

        let blank = ChatPane.takingBack(question, from: [kept, question], draft: "  ")
        #expect(blank.history == [kept])
        #expect(blank.draft == "What was decided?")

        let typing = ChatPane.takingBack(question, from: [kept, question], draft: "something else")
        #expect(typing.history == [kept, question])
        #expect(typing.draft == "something else")
    }

    @Test("a failed send hands its question back through the same helper")
    func failedSendGivesTheQuestionBack() throws {
        let path = #filePath.replacingOccurrences(of: "ParolaAppTests/LiveReplyTests.swift", with: "ParolaApp/Views/Chat/ChatPane.swift")
        let pane = try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(pane.contains("giveBack(question) turnError = FailureText.message(for: error)"))
    }

    @Test("the live bubble follows the search and sender filters like any other")
    func liveBubbleObeysFilters() {
        let reply = ChatMessage(role: .assistant, text: "We ship on Friday")
        #expect(ChatMessageList.matches(reply, searchQuery: "friday", senderFilter: .all))
        #expect(!ChatMessageList.matches(reply, searchQuery: "monday", senderFilter: .all))
        #expect(!ChatMessageList.matches(reply, searchQuery: "", senderFilter: .user))
    }
}
