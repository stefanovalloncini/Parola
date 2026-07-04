import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("Debounced transcript persistence")
struct DebouncedPersistenceTests {

    private func makeIsolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-\(UUID())")!
    }

    private func makeModel() -> AppModel {
        AppModel(skipBootstrap: true, defaults: makeIsolatedDefaults(), libraryURL: makeTempLibraryURL("debounce"))
    }

    private static func seedEntry(in model: AppModel) async throws -> LibraryEntry {
        let seedStore = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        return try await seedStore.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "original")],
                language: "en",
                modelName: "stub"
            ),
            audioSource: nil,
            category: .transcription
        )
    }

    @Test("two rapid edits coalesce into one write")
    func rapidEditsCoalesce() async throws {
        let model = makeModel()
        let entry = try await Self.seedEntry(in: model)
        model.selectedEntryID = entry.id
        model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "original")],
            language: "en",
            modelName: "stub"
        )

        model.editSegment(id: 0, newText: "edit one")
        model.editSegment(id: 0, newText: "edit two")

        await model.flushPendingTranscriptSave()

        let loaded = try await model.library.load(entry.id)
        #expect(loaded.document.transcript.segments[0].text == "edit two")
    }

    @Test("flush on entry switch persists the last edit")
    func flushOnEntrySwitch() async throws {
        let model = makeModel()
        let entry = try await Self.seedEntry(in: model)
        model.selectedEntryID = entry.id
        model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "original")],
            language: "en",
            modelName: "stub"
        )

        model.editSegment(id: 0, newText: "edited before switch")

        let entry2 = try await Self.seedEntry(in: model)
        model.loadEntry(entry2.id)
        var switched = false
        for _ in 0..<200 {
            if model.selectedEntryID == entry2.id { switched = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(switched)

        let loaded = try await model.library.load(entry.id)
        #expect(loaded.document.transcript.segments[0].text == "edited before switch")
    }

    @Test("timing-only nudge does not trigger a search re-index")
    func timingNudgeSkipsReindex() async throws {
        let store = LibraryStore(libraryURL: makeTempLibraryURL("reindex"), extraIndexer: nil)
        let entry = try await store.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "hello world")],
                language: "en",
                modelName: "stub"
            ),
            audioSource: nil,
            category: .transcription
        )
        let before = await store.search("hello")
        #expect(before.count == 1)

        let nudged = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0.1, end: 1.1, text: "hello world")],
            language: "en",
            modelName: "stub"
        )
        try await store.updateTranscript(nudged, for: entry.id, reindex: false)

        let after = await store.search("hello")
        #expect(after.count == 1)
    }

    @Test("text edit still triggers re-index")
    func textEditReindexes() async throws {
        let store = LibraryStore(libraryURL: makeTempLibraryURL("reindex2"), extraIndexer: nil)
        let entry = try await store.add(
            transcript: Transcript(
                segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "hello world")],
                language: "en",
                modelName: "stub"
            ),
            audioSource: nil,
            category: .transcription
        )

        let updated = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "goodbye universe")],
            language: "en",
            modelName: "stub"
        )
        try await store.updateTranscript(updated, for: entry.id, reindex: true)

        let helloResults = await store.search("hello")
        let goodbyeResults = await store.search("goodbye")
        #expect(helloResults.count == 0)
        #expect(goodbyeResults.count == 1)
    }
}
