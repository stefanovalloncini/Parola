import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("ChatPane history updates")
struct ChatPaneHistoryTests {
    @Test("a delta landing on an emptied history appends instead of crashing")
    func deltaOnEmptyHistoryAppends() {
        let id = UUID()
        let updated = ChatPane.updatedHistory([], liveID: id, text: "hello")
        #expect(updated.map(\.text) == ["hello"])
        #expect(updated.first?.role == .assistant)
    }

    @Test("a delta replaces the in-flight assistant message by id")
    func deltaReplacesLiveMessage() {
        let id = UUID()
        let history = [
            ChatMessage(role: .user, text: "question"),
            ChatMessage(id: id, role: .assistant, text: "par"),
        ]
        let updated = ChatPane.updatedHistory(history, liveID: id, text: "partial reply")
        #expect(updated.map(\.text) == ["question", "partial reply"])
    }
}
