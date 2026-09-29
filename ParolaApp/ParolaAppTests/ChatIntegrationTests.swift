import Foundation
import Testing
import ParolaCore
@testable import Parola
import ParolaTestSupport

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
        temporaryDefaults()
    }

    private func makeModel(entryID: LibraryEntry.ID, transcript: Transcript) -> AppModel {
        let model = AppModel(skipBootstrap: true, defaults: makeIsolatedDefaults(), libraryURL: makeTempLibraryURL("chat"))
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

    @Test("recordChat saves the chat into the entry")
    func recordChatPersists() async throws {
        let model = AppModel(skipBootstrap: true, defaults: makeIsolatedDefaults(), libraryURL: makeTempLibraryURL("chat"))
        let seedStore = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let entry = try await seedStore.add(transcript: makeTranscript(), audioSource: nil, category: .transcription)
        model.transcript = makeTranscript()
        model.selectedEntryID = entry.id
        let history = [ChatMessage(role: .user, text: "what is this?"), ChatMessage(role: .assistant, text: "A test.")]

        model.recordChat(history: history, for: entry.id)

        var stored: [String]?
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while stored != ["what is this?", "A test."], ContinuousClock().now < deadline {
            stored = try await model.library.load(entry.id).document.transcript.chatHistory?.map(\.text)
            if stored == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(stored == ["what is this?", "A test."])
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
        let model = AppModel(skipBootstrap: true, defaults: makeIsolatedDefaults(), libraryURL: makeTempLibraryURL("chat"))
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
        let model = AppModel(skipBootstrap: true, defaults: makeIsolatedDefaults(), libraryURL: makeTempLibraryURL("chat"))
        model.transcript = makeTranscript()
        #expect(model.isSummarising == false)

        model.summariseTranscript()

        #expect(model.isSummarising)
    }

    @Test("summariseTranscript stays idle without a transcript")
    func thinkingFlagStaysOffWithoutTranscript() {
        let model = AppModel(skipBootstrap: true, defaults: makeIsolatedDefaults(), libraryURL: makeTempLibraryURL("chat"))
        model.transcript = nil

        model.summariseTranscript()

        #expect(model.isSummarising == false)
    }

    @Test("summariseTranscript ignores re-entry while already running")
    func thinkingFlagBlocksReentry() {
        let model = AppModel(skipBootstrap: true, defaults: makeIsolatedDefaults(), libraryURL: makeTempLibraryURL("chat"))
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
        model.summariseOperation = { _, _ in
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

    @Test("a summary started on A lands in A while B is open, and B's pane is not affected")
    func summaryLandsOnTheEntryThatAsked() async throws {
        let model = AppModel(skipBootstrap: true, defaults: makeIsolatedDefaults(), libraryURL: makeTempLibraryURL("chat"))
        let seedStore = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let a = try await seedStore.add(transcript: makeTranscript(), audioSource: nil, category: .transcription)
        let b = try await seedStore.add(transcript: makeTranscript(), audioSource: nil, category: .transcription)
        model.loadEntry(a.id)
        try await waitUntil { model.selectedEntryID == a.id && model.transcript != nil }
        let gate = SummariseGate()
        model.summariseOperation = { _, _ in
            await gate.wait()
            return Summary(text: "summary for A", chapters: [Chapter(title: "A opens", start: 0)])
        }

        model.summariseTranscript()
        #expect(model.isSummarising)

        model.loadEntry(b.id)
        try await waitUntil { model.selectedEntryID == b.id && model.transcript != nil }
        #expect(model.isSummarising == false)
        #expect(model.aiJobs.isRunning(.summary, for: a.id))

        gate.open()
        try await waitUntil { !model.aiJobs.isRunning(.summary, for: a.id) }

        #expect(model.transcript?.summary == nil)
        #expect(model.smartChapters.isEmpty)
        #expect(try await model.library.load(b.id).document.transcript.summary == nil)
        let storedA = try await model.library.load(a.id).document.transcript
        #expect(storedA.summary?.text == "summary for A")
        #expect(storedA.chapters?.map(\.title) == ["A opens"])

        model.loadEntry(a.id)
        try await waitUntil { model.selectedEntryID == a.id && model.transcript?.summary != nil }
        #expect(model.smartChapters.map(\.title) == ["A opens"])
    }

    @Test("deleting an entry stops its summary run, so nothing lands in the trashed bundle")
    func deleteCancelsTheRun() async throws {
        let model = AppModel(skipBootstrap: true, defaults: makeIsolatedDefaults(), libraryURL: makeTempLibraryURL("chat"))
        let seedStore = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let a = try await seedStore.add(transcript: makeTranscript(), audioSource: nil, category: .transcription)
        model.loadEntry(a.id)
        try await waitUntil { model.selectedEntryID == a.id && model.transcript != nil }
        let gate = SummariseGate()
        model.summariseOperation = { _, _ in
            await gate.wait()
            return Summary(text: "too late")
        }

        model.summariseTranscript()
        #expect(model.isSummarising)
        model.deleteEntry(a.id)
        try await waitUntil { model.selectedEntryID == nil }
        #expect(!model.aiJobs.isRunning(.summary, for: a.id))

        gate.open()
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await model.library.load(a.id).document.transcript.summary == nil)
    }

    @Test("Clear stops the summary run in flight and nothing lands afterwards")
    func clearCancelsTheRun() async throws {
        let model = AppModel(skipBootstrap: true, defaults: makeIsolatedDefaults(), libraryURL: makeTempLibraryURL("chat"))
        let seedStore = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let a = try await seedStore.add(transcript: makeTranscript(), audioSource: nil, category: .transcription)
        model.loadEntry(a.id)
        try await waitUntil { model.selectedEntryID == a.id && model.transcript != nil }
        let gate = SummariseGate()
        model.summariseOperation = { _, _ in
            await gate.wait()
            return Summary(text: "too late")
        }

        model.summariseTranscript()
        #expect(model.isSummarising)
        model.clearSummary()
        #expect(model.isSummarising == false)

        gate.open()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.transcript?.summary == nil)
        #expect(try await model.library.load(a.id).document.transcript.summary == nil)
    }

    @Test("a summary asked for right after a recording follows the transcript into its new entry")
    func summariseSurvivesTheLibrarySaveThatSelectsIt() async throws {
        let model = AppModel(skipBootstrap: true, defaults: makeIsolatedDefaults(), libraryURL: makeTempLibraryURL("chat"))
        let transcript = makeTranscript()
        model.transcript = transcript
        let gate = SummariseGate()
        model.summariseOperation = { _, _ in
            await gate.wait()
            return Summary(text: "fresh take summary", chapters: [])
        }

        model.persistToLibrary(transcript, audioSource: nil, source: .file)
        model.summariseTranscript()
        #expect(model.selectedEntryID == nil, "library.add is still running when the user hits Summarise")
        #expect(model.isSummarising)

        try await waitUntil { model.selectedEntryID != nil }
        gate.open()
        try await waitUntil { !model.isSummarising }

        #expect(model.transcript?.summary?.text == "fresh take summary")
        let entryID = try #require(model.selectedEntryID)
        var stored: Summary?
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while stored == nil, ContinuousClock().now < deadline {
            stored = try await model.library.load(entryID).document.transcript.summary
            if stored == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(stored?.text == "fresh take summary")
    }

    @Test("a summary of an unsaved transcript is dropped when the user opens another entry")
    func summariseDropsWhenNavigatingAwayFromAnUnsavedTranscript() async throws {
        let model = AppModel(skipBootstrap: true, defaults: makeIsolatedDefaults(), libraryURL: makeTempLibraryURL("chat"))
        let seedStore = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let seeded = try await seedStore.add(transcript: makeTranscript(), audioSource: nil, category: .transcription)
        model.transcript = makeTranscript()
        let gate = SummariseGate()
        model.summariseOperation = { _, _ in
            await gate.wait()
            return Summary(text: "orphan summary", chapters: [])
        }

        model.summariseTranscript()
        model.loadEntry(seeded.id)
        try await waitUntil { model.selectedEntryID == seeded.id }

        gate.open()
        try await waitUntil { !model.isSummarising }

        #expect(model.transcript?.summary == nil)
    }

    @Test("summariseTranscript writes the summary into the open library entry")
    func summarisePersistsToLibraryEntry() async throws {
        let model = AppModel(skipBootstrap: true, defaults: makeIsolatedDefaults(), libraryURL: makeTempLibraryURL("chat"))
        let seedStore = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let transcript = makeTranscript()
        let seeded = try await seedStore.add(transcript: transcript, audioSource: nil, category: .transcription)
        model.transcript = transcript
        model.selectedEntryID = seeded.id
        model.summariseOperation = { _, _ in Summary(text: "persisted summary", chapters: []) }

        model.summariseTranscript()
        try await waitUntil { !model.isSummarising }
        #expect(model.transcript?.summary?.text == "persisted summary")

        var stored: Summary?
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while stored == nil, ContinuousClock().now < deadline {
            stored = try await model.library.load(seeded.id).document.transcript.summary
            if stored == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(stored?.text == "persisted summary")
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
