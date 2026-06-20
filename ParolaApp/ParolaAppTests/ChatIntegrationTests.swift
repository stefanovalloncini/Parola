import Foundation
import Testing
import ParolaCore
@testable import Parola

@Suite("AppModel chat integration")
@MainActor
struct ChatIntegrationTests {

    private func makeTranscript(chatHistory: [ChatMessage]? = nil) -> Transcript {
        Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "hello")],
            language: "en",
            modelName: "stub",
            chatHistory: chatHistory
        )
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-\(UUID())")!
    }

    private func makeModel(entryID: LibraryEntry.ID, transcript: Transcript) -> AppModel {
        let model = AppModel(skipBootstrap: true, defaults: makeIsolatedDefaults())
        model.transcript = transcript
        model.selectedEntryID = entryID
        return model
    }

    @Test("recordChat writes history onto the current transcript")
    func recordChatAppends() throws {
        let entryID: LibraryEntry.ID = "entry-1"
        let model = makeModel(entryID: entryID, transcript: makeTranscript())

        let history = [
            ChatMessage(role: .user, text: "what is this about?"),
            ChatMessage(role: .assistant, text: "It's a test."),
        ]
        model.recordChat(history: history, for: entryID)

        let stored = try #require(model.transcript?.chatHistory)
        #expect(stored.count == 2)
        #expect(stored.first?.role == .user)
        #expect(stored.first?.text == "what is this about?")
        #expect(stored.last?.role == .assistant)
    }

    @Test("recordChat replaces prior history on subsequent calls")
    func recordChatReplaces() {
        let entryID: LibraryEntry.ID = "entry-2"
        let initial = [ChatMessage(role: .user, text: "first")]
        let model = makeModel(entryID: entryID, transcript: makeTranscript(chatHistory: initial))

        let next = [
            ChatMessage(role: .user, text: "first"),
            ChatMessage(role: .assistant, text: "reply"),
            ChatMessage(role: .user, text: "follow up"),
        ]
        model.recordChat(history: next, for: entryID)

        #expect(model.transcript?.chatHistory?.count == 3)
        #expect(model.transcript?.chatHistory?.last?.text == "follow up")
    }

    @Test("recordChat is a no-op when entryID is nil")
    func recordChatRequiresEntryID() {
        let model = makeModel(entryID: "entry-3", transcript: makeTranscript())
        let before = model.transcript?.chatHistory

        model.recordChat(history: [ChatMessage(role: .user, text: "hi")], for: nil)

        #expect(model.transcript?.chatHistory == before)
    }

    @Test("recordChat ignores writes for a non-selected entry")
    func recordChatRequiresMatchingSelection() {
        let model = makeModel(entryID: "entry-A", transcript: makeTranscript())

        model.recordChat(history: [ChatMessage(role: .user, text: "hi")], for: "entry-B")

        #expect(model.transcript?.chatHistory == nil)
    }

    @Test("recordChat is a no-op when no transcript is loaded")
    func recordChatRequiresTranscript() {
        let model = AppModel(skipBootstrap: true, defaults: makeIsolatedDefaults())
        model.selectedEntryID = "entry-4"
        model.transcript = nil

        model.recordChat(history: [ChatMessage(role: .user, text: "hi")], for: "entry-4")

        #expect(model.transcript == nil)
    }

    @Test("empty history clears chatHistory on the transcript")
    func recordChatEmptyClears() {
        let entryID: LibraryEntry.ID = "entry-5"
        let seeded = [ChatMessage(role: .user, text: "hi")]
        let model = makeModel(entryID: entryID, transcript: makeTranscript(chatHistory: seeded))

        model.recordChat(history: [], for: entryID)

        #expect(model.transcript?.chatHistory?.isEmpty == true)
    }

    @Test("attaching multiple files stacks context blocks above the prompt")
    func multipleAttachmentsStack() {
        var composer = "summarise these"
        composer = ChatAttachment.attach(input: composer, filename: "a.md", content: "alpha")
        composer = ChatAttachment.attach(input: composer, filename: "b.md", content: "beta")

        #expect(composer.contains("a.md"))
        #expect(composer.contains("alpha"))
        #expect(composer.contains("b.md"))
        #expect(composer.contains("beta"))
        #expect(composer.contains("summarise these"))
    }

    @Test("attaching a file changes the composer payload")
    func singleAttachmentMutatesInput() {
        let base = "what does this mean?"
        let withOne = ChatAttachment.attach(input: base, filename: "x.txt", content: "data")
        #expect(withOne != base)
        #expect(withOne.contains("data"))
    }

    @Test("isReadableTextFile recognises the configured extensions")
    func attachmentExtensions() {
        #expect(ChatAttachment.isReadableTextFile(URL(fileURLWithPath: "/tmp/notes.md")))
        #expect(ChatAttachment.isReadableTextFile(URL(fileURLWithPath: "/tmp/transcript.srt")))
        #expect(ChatAttachment.isReadableTextFile(URL(fileURLWithPath: "/tmp/photo.png")) == false)
    }

    @Test("summariseTranscript flips the thinking flag when a transcript is loaded")
    func thinkingFlagStarts() {
        let model = AppModel(skipBootstrap: true, defaults: makeIsolatedDefaults())
        model.transcript = makeTranscript()
        #expect(model.isSummarising == false)

        model.summariseTranscript()

        #expect(model.isSummarising)
    }

    @Test("summariseTranscript stays idle without a transcript")
    func thinkingFlagStaysOffWithoutTranscript() {
        let model = AppModel(skipBootstrap: true, defaults: makeIsolatedDefaults())
        model.transcript = nil

        model.summariseTranscript()

        #expect(model.isSummarising == false)
    }

    @Test("summariseTranscript ignores re-entry while already running")
    func thinkingFlagBlocksReentry() {
        let model = AppModel(skipBootstrap: true, defaults: makeIsolatedDefaults())
        model.transcript = makeTranscript()
        model.summariseTranscript()
        #expect(model.isSummarising)

        model.summariseTranscript()

        #expect(model.isSummarising)
    }

    @Test("summariseTranscript attaches the summary after a benign duration bump")
    func summariseSurvivesDurationBump() async throws {
        let model = makeModel(entryID: "entry-sum", transcript: makeTranscript())
        let gate = SummariseGate()
        model.summariseOperation = { _ in
            await gate.wait()
            return Summary(text: "the summary", chapters: [])
        }

        model.summariseTranscript()
        #expect(model.isSummarising)

        model.transcript?.durationSeconds = 123

        gate.open()
        try await waitUntil { !model.isSummarising }

        #expect(model.transcript?.summary?.text == "the summary")
        #expect(model.isSummarising == false)
    }

    @Test("summariseTranscript drops the summary when the user switches entries")
    func summariseDropsOnEntrySwitch() async throws {
        let model = makeModel(entryID: "entry-A", transcript: makeTranscript())
        let gate = SummariseGate()
        model.summariseOperation = { _ in
            await gate.wait()
            return Summary(text: "summary for A", chapters: [])
        }

        model.summariseTranscript()
        #expect(model.isSummarising)

        model.transcript = makeTranscript()
        model.selectedEntryID = "entry-B"

        gate.open()
        try await waitUntil { !model.isSummarising }

        #expect(model.transcript?.summary == nil)
        #expect(model.isSummarising == false)
    }

    private func waitUntil(
        within timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while !condition() {
            try #require(ContinuousClock().now < deadline, "timed out waiting for condition")
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
private final class SummariseGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
