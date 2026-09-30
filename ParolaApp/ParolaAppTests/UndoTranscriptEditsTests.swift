import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

private struct ImmediateClock: Clock {
    typealias Instant = ContinuousClock.Instant
    var now: Instant { ContinuousClock().now }
    var minimumResolution: Duration { .zero }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        await Task.yield()
    }
}

@MainActor
@Suite("Transcript edit undo")
struct UndoTranscriptEditsTests {
    let model: AppModel
    let undo = UndoManager()

    init() {
        model = AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
            libraryURL: makeTempLibraryURL("undo")
        )
        // No run loop in tests, so the per-event group would never close; explicit groups in the seam keep each edit one step.
        undo.groupsByEvent = false
        model.undoManager = undo
        model.transcript = Self.makeTranscript()
    }

    static func makeTranscript() -> Transcript {
        Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 1, text: "Hello world.", speaker: "Speaker 1"),
                TranscriptSegment(id: 1, start: 1, end: 2, text: "Hello again.", speaker: "Speaker 2"),
                TranscriptSegment(id: 2, start: 2, end: 3, text: "Goodbye world.", speaker: "Speaker 1"),
            ],
            language: "en",
            modelName: "stub"
        )
    }

    private func openFind(query: String) {
        model.findIsOpen = true
        model.findQuery = query
        model.recomputeMatches()
    }

    @Test("edit segment round-trips through undo and redo")
    func editUndoRedoRoundTrip() {
        model.editSegment(id: 0, newText: "Howdy world.")
        #expect(model.transcript?.segments[0].text == "Howdy world.")
        #expect(undo.canUndo)

        undo.undo()
        #expect(model.transcript?.segments[0].text == "Hello world.")
        #expect(undo.canRedo)

        undo.redo()
        #expect(model.transcript?.segments[0].text == "Howdy world.")
        #expect(undo.canUndo)
    }

    @Test("undo of an edit restores the dropped word timings")
    func editUndoRestoresWordTimings() throws {
        var t = try #require(model.transcript)
        t.segments[0].words = [WordTiming(id: "0-0", word: "Hello", start: 0, end: 0.5, probability: 1)]
        model.transcript = t

        model.editSegment(id: 0, newText: "Changed text.")
        #expect(model.transcript?.segments[0].words == nil)

        undo.undo()
        #expect(model.transcript?.segments[0].words?.count == 1)
    }

    @Test("delete segment round-trips through undo and redo")
    func deleteUndoRedoRoundTrip() {
        model.deleteSegment(id: 1)
        #expect(model.transcript?.segments.map(\.id) == [0, 2])

        undo.undo()
        #expect(model.transcript?.segments.map(\.id) == [0, 1, 2])
        #expect(model.transcript?.segments[1].text == "Hello again.")

        undo.redo()
        #expect(model.transcript?.segments.map(\.id) == [0, 2])
    }

    @Test("timing nudge round-trips through undo and redo")
    func nudgeUndoRedoRoundTrip() {
        let nudged = 3.0 + 3.0 / 30.0
        model.nudgeSegmentEnd(id: 2, frames: 3)
        #expect(model.transcript?.segments[2].end == nudged)

        undo.undo()
        #expect(model.transcript?.segments[2].end == 3.0)

        undo.redo()
        #expect(model.transcript?.segments[2].end == nudged)
    }

    @Test("each nudge is its own undo step")
    func eachNudgeIsItsOwnUndoStep() {
        model.nudgeSegmentEnd(id: 2, frames: 3)
        let afterFirst = model.transcript?.segments[2].end
        model.nudgeSegmentEnd(id: 2, frames: 3)

        undo.undo()
        #expect(model.transcript?.segments[2].end == afterFirst)
        undo.undo()
        #expect(model.transcript?.segments[2].end == 3.0)
        #expect(!undo.canUndo)
    }

    @Test("replace current match round-trips through undo")
    func replaceCurrentMatchUndo() throws {
        openFind(query: "Hello")
        try #require(model.matches.count == 2)
        model.findReplacement = "Ciao"

        model.replaceCurrentMatch()
        #expect(model.transcript?.segments[0].text == "Ciao world.")

        undo.undo()
        #expect(model.transcript?.segments[0].text == "Hello world.")
    }

    @Test("replace all round-trips through undo and redo")
    func replaceAllUndoRedoRoundTrip() throws {
        openFind(query: "world")
        try #require(!model.matches.isEmpty)
        model.findReplacement = "planet"

        model.replaceAllMatches()
        #expect(model.transcript?.segments[0].text == "Hello planet.")
        #expect(model.transcript?.segments[2].text == "Goodbye planet.")

        undo.undo()
        #expect(model.transcript?.segments[0].text == "Hello world.")
        #expect(model.transcript?.segments[2].text == "Goodbye world.")

        undo.redo()
        #expect(model.transcript?.segments[2].text == "Goodbye planet.")
    }

    @Test("speaker rename round-trips through undo")
    func speakerRenameUndo() {
        model.applySpeakerRenames(["Speaker 1": "Alice"])
        #expect(model.transcript?.segments[0].speaker == "Alice")
        #expect(model.transcript?.segments[2].speaker == "Alice")
        #expect(model.transcript?.segments[1].speaker == "Speaker 2")

        undo.undo()
        #expect(model.transcript?.segments[0].speaker == "Speaker 1")
        #expect(model.transcript?.segments[2].speaker == "Speaker 1")
    }

    @Test("no-op mutations register no undo step")
    func noOpMutationsRegisterNothing() {
        model.editSegment(id: 0, newText: "Hello world.")
        model.editSegment(id: 0, newText: "   ")
        model.nudgeSegmentEnd(id: 2, frames: 0)
        model.deleteSegment(id: 99)
        model.applySpeakerRenames(["Speaker 1": "   "])
        #expect(!undo.canUndo)
    }

    @Test("Edit menu action names match the operations")
    func actionNamesMatchOperations() throws {
        model.editSegment(id: 0, newText: "Changed.")
        #expect(undo.undoActionName == "Edit Segment")

        model.nudgeSegmentEnd(id: 2, frames: 3)
        #expect(undo.undoActionName == "Adjust Timing")

        model.deleteSegment(id: 1)
        #expect(undo.undoActionName == "Delete Segment")

        openFind(query: "Changed")
        try #require(!model.matches.isEmpty)
        model.findReplacement = "Edited"
        model.replaceCurrentMatch()
        #expect(undo.undoActionName == "Replace")

        openFind(query: "world")
        try #require(!model.matches.isEmpty)
        model.replaceAllMatches()
        #expect(undo.undoActionName == "Replace All")

        model.applySpeakerRenames(["Speaker 1": "Alice"])
        #expect(undo.undoActionName == "Rename Speaker")

        undo.undo()
        #expect(undo.redoActionName == "Rename Speaker")
    }

    @Test("loading another entry clears the undo stack")
    func loadEntryClearsUndoStack() async throws {
        model.editSegment(id: 0, newText: "Edited before switch.")
        try #require(undo.canUndo)

        let seedStore = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let entry = try await seedStore.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "other")],
                language: "en",
                modelName: "stub"
            ),
            audioSource: nil,
            category: .transcription
        )
        model.loadEntry(entry.id)
        var switched = false
        for _ in 0..<200 {
            if model.selectedEntryID == entry.id { switched = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(switched)

        #expect(!undo.canUndo)
        #expect(!undo.canRedo)
    }

    @Test("undo registered for another entry context is a no-op")
    func undoNoOpsWhenEntryContextChanged() {
        model.editSegment(id: 0, newText: "Changed.")
        model.selectedEntryID = "some-other-entry"

        undo.undo()
        #expect(model.transcript?.segments[0].text == "Changed.")
    }

    @Test("undoing a text edit re-indexes search via the persistence pipeline")
    func undoOfTextEditReindexes() async throws {
        let bootstrap = AppBootstrap(
            mode: .test,
            library: makeTempLibraryURL("undo-reindex"),
            defaultsOverride: temporaryDefaults(),
            sideEffects: [],
            filePicker: TestFilePicker(),
            clock: ImmediateClock()
        )
        let model = AppModel(bootstrap: bootstrap)
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo

        let seedStore = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let seed = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "original")],
            language: "en",
            modelName: "stub"
        )
        let entry = try await seedStore.add(transcript: seed, audioSource: nil, category: .transcription)
        model.selectedEntryID = entry.id
        model.transcript = seed

        model.editSegment(id: 0, newText: "kryptonite")
        try await waitForPendingSave(model)
        #expect(await model.library.search("kryptonite").count == 1)

        undo.undo()
        #expect(model.transcript?.segments[0].text == "original")
        try await waitForPendingSave(model)

        #expect(await model.library.search("kryptonite").count == 0)
        #expect(await model.library.search("original").count == 1)
    }

    @Test("undoing an edit keeps the chapters and summary made after it, on disk too")
    func undoKeepsLaterSummaryAndChapters() async throws {
        let bootstrap = AppBootstrap(
            mode: .test,
            library: makeTempLibraryURL("undo-generated"),
            defaultsOverride: temporaryDefaults(),
            sideEffects: [],
            filePicker: TestFilePicker(),
            clock: ImmediateClock()
        )
        let model = AppModel(bootstrap: bootstrap)
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        let seedStore = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let seed = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "original")],
            language: "en",
            modelName: "stub"
        )
        let entry = try await seedStore.add(transcript: seed, audioSource: nil, category: .transcription)
        model.selectedEntryID = entry.id
        model.transcript = seed

        model.editSegment(id: 0, newText: "edited")
        let chapters = [Chapter(title: "Opening", start: 0)]
        model.smartChapters = chapters
        model.persistChapters(chapters)
        model.summariseOperation = { _, _ in Summary(text: "recap") }
        model.summariseTranscript()
        let summaryLanded = await waitUntil { !model.isSummarising && model.transcript?.summary?.text == "recap" }
        #expect(summaryLanded)

        undo.undo()
        #expect(model.transcript?.segments[0].text == "original")
        #expect(model.transcript?.summary?.text == "recap")
        #expect(model.transcript?.chapters == chapters)
        try await waitForPendingSave(model)
        let storedWait = await waitUntil {
            guard let stored = try? await model.library.load(entry.id).document.transcript else { return false }
            return stored.segments.first?.text == "original" && stored.summary?.text == "recap" && stored.chapters == chapters
        }
        #expect(storedWait)

        undo.redo()
        #expect(model.transcript?.segments[0].text == "edited")
        #expect(model.transcript?.summary?.text == "recap")
    }

    @Test("undo keeps a translation made after the edit, and rejoins a split's halves")
    func undoCarriesALaterTranslation() {
        let before = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 2, text: "hello world"),
                TranscriptSegment(id: 1, start: 2, end: 4, text: "second"),
            ],
            language: "en",
            modelName: "stub"
        )
        var live = before
        live.segments = [
            TranscriptSegment(id: 5, start: 0, end: 1, text: "hello"),
            TranscriptSegment(id: 6, start: 1, end: 2, text: "world"),
            TranscriptSegment(id: 1, start: 2, end: 4, text: "second"),
        ]
        live.translation = TranscriptTranslation(
            targetLanguage: "it", segments: [5: "ciao", 6: "mondo", 1: "secondo"], createdAt: .now, provider: "mock"
        )
        live.chatHistory = [ChatMessage(role: .user, text: "what was said?")]

        let restored = before.restoring(generatedIn: live, translationAfterEdit: nil)
        #expect(restored.segments == before.segments)
        #expect(restored.translation?.segments == [0: "ciao mondo", 1: "secondo"])
        #expect(restored.translation?.targetLanguage == "it")
        #expect(restored.chatHistory == live.chatHistory)

        let redone = live.restoring(generatedIn: restored, translationAfterEdit: nil)
        #expect(redone.translation?.segments == [5: "ciao mondo", 1: "secondo"])

        let unchanged = before.restoring(generatedIn: live, translationAfterEdit: live.translation)
        #expect(unchanged.translation == nil)
    }

    private func waitForPendingSave(_ model: AppModel) async throws {
        for _ in 0..<100 {
            if model.pendingTranscriptSaveTask == nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("debounced save never fired")
    }
}
