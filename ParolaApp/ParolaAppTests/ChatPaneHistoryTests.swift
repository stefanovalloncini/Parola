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

@MainActor
@Suite("ChatPane session loads")
struct ChatPaneSessionLoadTests {
    private struct SilentModel: LanguageModel {
        func respond(history: [ChatTurn]) async throws -> String { "" }
    }

    /// The selection the pane reads after each await.
    @MainActor
    private final class Selection {
        var key: ChatSessionKey
        init(_ key: ChatSessionKey) { self.key = key }
    }

    /// Holds a build open until the test lets it finish.
    private actor Gate {
        private var waiter: CheckedContinuation<Void, Never>?
        private var isOpen = false
        private(set) var isWaiting = false

        func wait() async {
            guard !isOpen else { return }
            isWaiting = true
            await withCheckedContinuation { waiter = $0 }
        }

        func open() {
            isOpen = true
            waiter?.resume()
            waiter = nil
        }
    }

    private struct BuildFailed: Error {}

    private static let entryA = ChatSessionKey(entryID: "a", hasTranscript: true)
    private static let entryB = ChatSessionKey(entryID: "b", hasTranscript: true)

    private static func session(_ text: String, history: [ChatMessage] = []) -> TranscriptChatSession {
        TranscriptChatSession(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: text)],
                language: "en",
                modelName: "stub"
            ),
            history: history,
            model: SilentModel()
        )
    }

    @Test("a session built for an entry the pane has left is dropped")
    func supersededBuildIsDropped() async {
        let selection = Selection(Self.entryA)
        let loaded = await ChatPane.loadSession(key: Self.entryA, currentKey: { selection.key }) {
            selection.key = Self.entryB
            return Self.session("entry a")
        }
        #expect(loaded == nil)
    }

    @Test("two quick switches install only the selected entry's session and history")
    func backToBackSwitchesKeepTheSelectedEntry() async throws {
        let selection = Selection(Self.entryA)
        let gate = Gate()
        let slow = Task {
            await ChatPane.loadSession(key: Self.entryA, currentKey: { selection.key }) {
                await gate.wait()
                return Self.session("entry a", history: [ChatMessage(role: .user, text: "about a")])
            }
        }
        while await !gate.isWaiting { await Task.yield() }

        selection.key = Self.entryB
        let fast = await ChatPane.loadSession(key: Self.entryB, currentKey: { selection.key }) {
            Self.session("entry b")
        }
        await gate.open()
        let late = await slow.value

        #expect(late == nil)
        guard case .ready(let installed, let history)? = fast else {
            Issue.record("the selected entry's session did not load")
            return
        }
        #expect(await installed.transcript.segments.first?.text == "entry b")
        #expect(history.isEmpty)
    }

    @Test("a failed build reports only while its entry is still selected")
    func failureFollowsTheSelection() async {
        let selection = Selection(Self.entryA)
        let current = await ChatPane.loadSession(key: Self.entryA, currentKey: { selection.key }) {
            throw BuildFailed()
        }
        guard case .failed? = current else {
            Issue.record("a failure on the selected entry should surface")
            return
        }

        let stale = await ChatPane.loadSession(key: Self.entryA, currentKey: { selection.key }) {
            selection.key = Self.entryB
            throw BuildFailed()
        }
        #expect(stale == nil)
    }

    @Test("a cancelled load installs nothing")
    func cancelledLoadInstallsNothing() async {
        let task = Task {
            await ChatPane.loadSession(key: Self.entryA, currentKey: { Self.entryA }) {
                withUnsafeCurrentTask { $0?.cancel() }
                return Self.session("entry a")
            }
        }
        #expect(await task.value == nil)
    }
}
