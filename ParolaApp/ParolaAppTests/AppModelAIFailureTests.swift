import Foundation
import Testing
import ParolaCore
@testable import Parola

@MainActor
@Suite("AppModel AI failures", .serialized)
struct AppModelAIFailureTests {

    private func makeModel() -> AppModel {
        let model = AppModel(
            skipBootstrap: true,
            defaults: UserDefaults(suiteName: "test-\(UUID())")!,
            libraryURL: makeTempLibraryURL("ai-failure")
        )
        model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 4, text: "we ship the patch on Friday")],
            language: "en",
            modelName: "stub"
        )
        model.phase = .ready
        return model
    }

    private func installFailingModel() async {
        await MockLanguageModelStore.shared.clear()
        await MockLanguageModelStore.shared.install(
            provider: .foundation,
            response: MockLanguageModelResponse(
                failure: MockLanguageModelFailure(code: .notAvailable, message: "Apple Intelligence is off.")
            )
        )
    }

    private func waitUntil(timeoutMs: Int = 3000, _ condition: @MainActor () -> Bool) async -> Bool {
        var elapsed = 0
        while elapsed < timeoutMs {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(15))
            elapsed += 15
        }
        return condition()
    }

    @Test("a failed prompt reports in its own sheet and leaves the transcript on screen")
    func promptFailureKeepsTranscriptVisible() async throws {
        await installFailingModel()
        let model = makeModel()

        model.runPrompt(try #require(Prompt.builtIns.first))
        #expect(await waitUntil { model.promptOutput != nil })

        #expect(model.phase == .ready)
        #expect(model.promptOutput?.failure?.contains("Apple Intelligence is off.") == true)
        await MockLanguageModelStore.shared.clear()
    }

    @Test("a failed action-item extraction reports in the inspector, not as an app failure")
    func actionItemFailureStaysInSection() async {
        await installFailingModel()
        let model = makeModel()

        model.extractActionItems()
        #expect(await waitUntil { model.actionItemsError != nil })

        #expect(model.phase == .ready)
        #expect(model.actionItems.isEmpty)
        await MockLanguageModelStore.shared.clear()
    }

    @Test("a failed chapter extraction reports in the inspector, not as an app failure")
    func chapterFailureStaysInSection() async {
        await installFailingModel()
        let model = makeModel()

        model.extractSmartChapters()
        #expect(await waitUntil { model.chaptersError != nil })

        #expect(model.phase == .ready)
        #expect(model.smartChapters.isEmpty)
        await MockLanguageModelStore.shared.clear()
    }

    @Test("generated chapters replace the ones the entry saved")
    func generatedChaptersOverrideSavedOnes() async {
        await MockLanguageModelStore.shared.clear()
        await MockLanguageModelStore.shared.install(
            provider: .foundation,
            response: MockLanguageModelResponse(text: "00:00 Fresh opening\n00:30 Fresh close")
        )
        let model = makeModel()
        model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 120, text: "we ship the patch on Friday")],
            language: "en",
            modelName: "stub",
            summary: Summary(text: "saved recap", chapters: [Chapter(title: "Saved opening", start: 0)])
        )
        model.adoptSavedChapters()
        #expect(model.smartChapters.map(\.title) == ["Saved opening"])

        model.extractSmartChapters()

        #expect(await waitUntil { model.smartChapters.map(\.title) == ["Fresh opening", "Fresh close"] })
        #expect(model.transcript?.summary?.chapters.map(\.title) == ["Fresh opening", "Fresh close"])
        await MockLanguageModelStore.shared.clear()
    }

    @Test("clearing chapters empties the saved summary too")
    func clearingChaptersWritesThrough() {
        let model = makeModel()
        model.transcript = Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 4, text: "hello")],
            language: "en",
            modelName: "stub",
            summary: Summary(text: "saved recap", chapters: [Chapter(title: "Saved opening", start: 0)])
        )
        model.adoptSavedChapters()

        model.clearSmartChapters()

        #expect(model.smartChapters.isEmpty)
        #expect(model.transcript?.summary?.chapters.isEmpty == true)
        #expect(model.transcript?.summary?.text == "saved recap")
    }

    @Test("an entry with no saved summary keeps its generated chapters in memory")
    func generatedChaptersWithoutASummaryStayInMemory() async {
        await MockLanguageModelStore.shared.clear()
        await MockLanguageModelStore.shared.install(
            provider: .foundation,
            response: MockLanguageModelResponse(text: "00:00 Fresh opening")
        )
        let model = makeModel()

        model.extractSmartChapters()

        #expect(await waitUntil { model.smartChapters.map(\.title) == ["Fresh opening"] })
        #expect(model.transcript?.summary == nil)
        await MockLanguageModelStore.shared.clear()
    }

    @Test("clearing derived artifacts drops the AI errors too")
    func clearDerivedArtifactsClearsErrors() {
        let model = makeModel()
        model.actionItemsError = "boom"
        model.chaptersError = "boom"

        model.clearDerivedArtifacts()

        #expect(model.actionItemsError == nil)
        #expect(model.chaptersError == nil)
    }

    @Test("dismissing an error returns to the loaded transcript")
    func dismissReturnsToTranscript() {
        let model = makeModel()
        model.phase = .failed(message: "boom")

        model.dismissError()

        #expect(model.phase == .ready)
    }

    @Test("dismissing an error with no transcript returns to the launcher")
    func dismissWithoutTranscriptGoesIdle() {
        let model = makeModel()
        model.transcript = nil
        model.phase = .failed(message: "boom")

        model.dismissError()

        #expect(model.phase == .idle)
    }

    @Test("an installed mock counts as available so AI affordances stay live in test mode")
    func mockKeepsAIAvailable() async {
        await MockLanguageModelStore.shared.clear()
        await MockLanguageModelStore.shared.install(
            provider: .foundation,
            response: MockLanguageModelResponse(text: "ok")
        )

        #expect(await LanguageModelFactory.onDeviceAvailability().isAvailable)
        await MockLanguageModelStore.shared.clear()
    }
}
