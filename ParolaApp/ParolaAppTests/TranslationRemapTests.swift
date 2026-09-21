import AppKit
import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Translation remap through the model", .serialized)
struct TranslationRemapTests {

    private func makeModel() -> AppModel {
        AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("translation-remap"))
    }

    private func translatedTranscript() -> Transcript {
        var transcript = Transcript(
            segments: [
                TranscriptSegment(id: 0, start: 0, end: 2, text: "hello world"),
                TranscriptSegment(id: 1, start: 2, end: 4, text: "second segment"),
            ],
            language: "en",
            modelName: "stub"
        )
        transcript.translation = TranscriptTranslation(
            targetLanguage: "it",
            segments: [0: "ciao mondo", 1: "secondo segmento"],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            provider: "mock"
        )
        return transcript
    }

    private func loadedModel() async throws -> (AppModel, LibraryEntry.ID) {
        let model = makeModel()
        let seedStore = LibraryStore(libraryURL: model.library.libraryURL, extraIndexer: nil)
        let seeded = try await seedStore.add(
            transcript: translatedTranscript(), audioSource: nil, category: .transcription
        )
        model.loadEntry(seeded.id)
        for _ in 0..<200 where model.selectedEntryID != seeded.id {
            try await Task.sleep(for: .milliseconds(10))
        }
        return (model, seeded.id)
    }

    private func withUndo(_ model: AppModel) -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        return undo
    }

    @Test("splitting moves the translation to the first half and undo puts it back")
    func splitRemapsAndUndoes() async throws {
        let (model, _) = try await loadedModel()
        let undo = withUndo(model)
        let before = try #require(model.transcript?.translation)

        model.splitSegment(id: 0, atFraction: 0.5)

        let firstID = try #require(model.transcript?.segments.first?.id)
        let secondID = try #require(model.transcript?.segments.dropFirst().first?.id)
        #expect(model.transcript?.translation?.segments[firstID] == "ciao mondo")
        #expect(model.transcript?.translation?.segments[secondID] == nil)
        #expect(model.transcript?.translation?.segments[1] == "secondo segmento")

        undo.undo()
        #expect(model.transcript?.translation == before)
    }

    @Test("merging joins both translations and undo puts them back")
    func mergeRemapsAndUndoes() async throws {
        let (model, _) = try await loadedModel()
        let undo = withUndo(model)
        let before = try #require(model.transcript?.translation)

        model.mergeSegmentWithNext(id: 0)

        #expect(model.transcript?.translation?.segments == [0: "ciao mondo secondo segmento"])

        undo.undo()
        #expect(model.transcript?.translation == before)
    }

    @Test("deleting drops the segment's translation and undo puts it back")
    func deleteRemapsAndUndoes() async throws {
        let (model, _) = try await loadedModel()
        let undo = withUndo(model)
        let before = try #require(model.transcript?.translation)

        model.deleteSegment(id: 0)

        #expect(model.transcript?.translation?.segments == [1: "secondo segmento"])

        undo.undo()
        #expect(model.transcript?.translation == before)
    }

    @Test("fixing a typo keeps the segment's translation")
    func editKeepsTranslation() async throws {
        let (model, _) = try await loadedModel()

        model.editSegment(id: 0, newText: "hello worlds")

        #expect(model.transcript?.segments.first?.text == "hello worlds")
        #expect(model.transcript?.translation?.segments[0] == "ciao mondo")
    }
}
