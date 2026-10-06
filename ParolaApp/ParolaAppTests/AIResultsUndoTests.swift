import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Undoing cleared and replaced AI results")
struct AIResultsUndoTests {
    let model: AppModel
    let undo = UndoManager()

    init() {
        let bootstrap = AppBootstrap(
            mode: .test,
            library: makeTempLibraryURL("ai-undo"),
            defaultsOverride: temporaryDefaults(),
            sideEffects: [],
            filePicker: TestFilePicker(),
            enabledFeaturesOverride: Set(ParolaFeature.allCases)
        )
        model = AppModel(bootstrap: bootstrap)
        undo.groupsByEvent = false
        model.undoManager = undo
    }

    private static let chapters = [Chapter(title: "Opening", start: 0)]
    private static let items = [ActionItem(task: "Send the slides")]

    private func open(_ seed: Transcript) async throws -> LibraryEntry.ID {
        let entry = try await model.library.add(transcript: seed, audioSource: nil, category: .transcription)
        model.selectedEntryID = entry.id
        model.transcript = seed
        model.adoptSavedChapters()
        model.actionItems = seed.actionItems ?? []
        return entry.id
    }

    private static func seed() -> Transcript {
        var seed = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 2, text: "we ship on Friday")],
            language: "en",
            modelName: "stub"
        )
        seed.install(summary: Summary(text: "recap", chapters: chapters))
        seed.actionItems = items
        seed.translation = TranscriptTranslation(targetLanguage: "it", segments: [0: "spediamo venerdì"], createdAt: Date(), provider: "mock")
        return seed
    }

    private func stored(_ id: LibraryEntry.ID) async -> Transcript? {
        try? await model.library.load(id).document.transcript
    }

    @Test("Clear Summary undoes and redoes, on screen and on disk")
    func clearSummaryUndoes() async throws {
        let id = try await open(Self.seed())
        model.clearSummary()
        #expect(model.transcript?.summary == nil)
        #expect(undo.undoActionName == "Clear Summary")

        undo.undo()
        #expect(model.transcript?.summary?.text == "recap")
        #expect(model.smartChapters == Self.chapters)
        let restored = await waitUntil { await stored(id)?.summary?.text == "recap" }
        #expect(restored)

        undo.redo()
        #expect(model.transcript?.summary == nil)
        let cleared = await waitUntil { await stored(id)?.summary == nil }
        #expect(cleared)
    }

    @Test("Clear Chapters and Clear Action Items undo")
    func clearChaptersAndItemsUndo() async throws {
        let id = try await open(Self.seed())
        model.clearSmartChapters()
        #expect(model.smartChapters.isEmpty)
        #expect(undo.undoActionName == "Clear Chapters")
        model.clearActionItems()
        #expect(model.actionItems.isEmpty)
        #expect(undo.undoActionName == "Clear Action Items")

        undo.undo()
        #expect(model.actionItems == Self.items)
        #expect(model.transcript?.actionItems == Self.items)
        undo.undo()
        #expect(model.smartChapters == Self.chapters)
        #expect(model.transcript?.chapters == Self.chapters)
        let restored = await waitUntil {
            let disk = await stored(id)
            return disk?.chapters == Self.chapters && disk?.actionItems == Self.items
        }
        #expect(restored)
    }

    @Test("undo writes back only what it restores, not results another run saved meanwhile")
    func undoWritesOnlyWhatItRestores() async throws {
        let id = try await open(Self.seed())
        model.clearSummary()
        let cleared = await waitUntil { await stored(id)?.summary == nil }
        #expect(cleared)
        let newItems = [ActionItem(task: "Book the room")]
        let newChapters = [Chapter(title: "Close", start: 1)]
        try await model.library.setActionItems(newItems, for: id)
        try await model.library.setChapters(newChapters, for: id)

        undo.undo()
        let restored = await waitUntil { await stored(id)?.summary?.text == "recap" }
        #expect(restored)
        let disk = await stored(id)
        #expect(disk?.actionItems == newItems)
        #expect(disk?.chapters == newChapters)
        #expect(disk?.summary?.chapters == newChapters)
    }

    @Test("a summary run that replaces one can be undone back to the old one")
    func regeneratedSummaryUndoes() async throws {
        let id = try await open(Self.seed())
        model.summariseOperation = { _, _ in Summary(text: "fresh recap") }
        model.summariseTranscript()
        let landed = await waitUntil { !model.isSummarising && model.transcript?.summary?.text == "fresh recap" }
        #expect(landed)
        #expect(undo.undoActionName == "Regenerate Summary")

        undo.undo()
        #expect(model.transcript?.summary?.text == "recap")
        let restored = await waitUntil { await stored(id)?.summary?.text == "recap" }
        #expect(restored)
    }

    @Test("a first summary leaves nothing to undo")
    func firstSummaryRegistersNothing() async throws {
        var seed = Self.seed()
        seed.summary = nil
        _ = try await open(seed)
        model.summariseOperation = { _, _ in Summary(text: "first recap") }
        model.summariseTranscript()
        let landed = await waitUntil { !model.isSummarising && model.transcript?.summary?.text == "first recap" }
        #expect(landed)
        #expect(!undo.canUndo)
    }

    @Test("Remove Translation undoes")
    func removeTranslationUndoes() async throws {
        let id = try await open(Self.seed())
        await model.removeTranslation()
        #expect(model.transcript?.translation == nil)
        #expect(undo.undoActionName == "Remove Translation")

        undo.undo()
        #expect(model.transcript?.translation?.segments[0] == "spediamo venerdì")
        let restored = await waitUntil { await stored(id)?.translation?.targetLanguage == "it" }
        #expect(restored)
    }

    @Test("undo leaves another entry's results alone")
    func undoStaysOnItsEntry() async throws {
        _ = try await open(Self.seed())
        model.clearSummary()
        let otherID = try await open(Self.seed())
        model.transcript?.summary = nil
        undo.undo()
        #expect(model.selectedEntryID == otherID)
        #expect(model.transcript?.summary == nil)
    }

    @Test("clearing a chat asks first, behind a trash glyph")
    func clearChatAsksFirst() throws {
        let path = #filePath.replacingOccurrences(
            of: "ParolaAppTests/AIResultsUndoTests.swift",
            with: "ParolaApp/Views/Chat/ChatPane.swift"
        )
        let source = try String(contentsOfFile: path, encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(source.contains(#".confirmationDialog("Clear this conversation?""#))
        #expect(source.contains(#"Button("Clear Conversation", role: .destructive) { resetConversation() }"#))
        #expect(source.contains(#"Image(systemName: "trash")"#))
        #expect(!source.contains(#"Image(systemName: "arrow.counterclockwise")"#))
    }
}
