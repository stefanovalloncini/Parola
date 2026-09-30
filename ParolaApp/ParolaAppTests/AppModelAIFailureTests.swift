import Foundation
import Testing
import ParolaCore
@testable import Parola
import ParolaTestSupport

@MainActor
@Suite("AppModel AI failures", .serialized)
struct AppModelAIFailureTests {

    private func makeModel() -> AppModel {
        let model = AppModel(
            skipBootstrap: true,
            defaults: temporaryDefaults(),
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

    /// Takes the store's lease, installs the mocks, runs the body and clears them whether it returns
    /// or throws. The store is process-global while swift-testing runs suites in parallel, so
    /// without the lease another suite resolves these slots mid-test.
    private func withOnDeviceMock<T: Sendable>(
        _ response: MockLanguageModelResponse,
        _ body: @MainActor () async throws -> T
    ) async rethrows -> T {
        try await MockLanguageModelStore.shared.withLease {
            await MockLanguageModelStore.shared.clear()
            await MockLanguageModelStore.shared.install(provider: .foundation, response: response)
            do {
                let value = try await body()
                await MockLanguageModelStore.shared.clear()
                return value
            } catch {
                await MockLanguageModelStore.shared.clear()
                throw error
            }
        }
    }

    private static let failingModel = MockLanguageModelResponse(
        failure: MockLanguageModelFailure(code: .notAvailable, message: "Apple Intelligence is off.")
    )

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
        try await withOnDeviceMock(Self.failingModel) {
            let model = makeModel()

            model.runPrompt(try #require(Prompt.builtIns.first))
            #expect(await waitUntil { model.promptOutput != nil })

            #expect(model.phase == .ready)
            #expect(model.promptOutput?.failure?.contains("Apple Intelligence is off.") == true)
        }
    }

    @Test("a failed action-item extraction reports in the inspector, not as an app failure")
    func actionItemFailureStaysInSection() async {
        await withOnDeviceMock(Self.failingModel) {
            let model = makeModel()

            model.extractActionItems()
            #expect(await waitUntil { model.actionItemsError != nil })

            #expect(model.phase == .ready)
            #expect(model.actionItems.isEmpty)
        }
    }

    @Test("a failed chapter extraction reports in the inspector, not as an app failure")
    func chapterFailureStaysInSection() async {
        await withOnDeviceMock(Self.failingModel) {
            let model = makeModel()

            model.extractSmartChapters()
            #expect(await waitUntil { model.chaptersError != nil })

            #expect(model.phase == .ready)
            #expect(model.smartChapters.isEmpty)
        }
    }

    @Test("generated chapters replace the ones the entry saved")
    func generatedChaptersOverrideSavedOnes() async {
        await withOnDeviceMock(MockLanguageModelResponse(text: "00:00 Fresh opening\n00:30 Fresh close")) {
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
        }
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

    @Test("an entry with no saved summary keeps its generated chapters without growing a summary")
    func generatedChaptersWithoutASummaryAreKept() async {
        await withOnDeviceMock(MockLanguageModelResponse(text: "00:00 Fresh opening")) {
            let model = makeModel()

            model.extractSmartChapters()

            #expect(await waitUntil { model.smartChapters.map(\.title) == ["Fresh opening"] })
            #expect(model.transcript?.chapters?.map(\.title) == ["Fresh opening"])
            #expect(model.transcript?.summary == nil)
        }
    }

    @Test("a summary lands with one chapter list: its own, else the kept one, even after Clear")
    func summaryAndChaptersStayOneList() {
        let generated = [Chapter(title: "Generated", start: 0)]
        let summarized = [Chapter(title: "Summarized", start: 0)]
        var transcript = Transcript(segments: [], language: "en", modelName: "stub", chapters: generated)

        transcript.install(summary: Summary(text: "recap", chapters: summarized))
        #expect(transcript.chapters == summarized)
        #expect(transcript.summary?.chapters == summarized)

        transcript.install(summary: Summary(text: "shorter recap"))
        #expect(transcript.chapters == summarized)
        #expect(transcript.summary?.chapters == summarized)

        transcript.chapters = []
        transcript.summary?.chapters = []
        transcript.install(summary: Summary(text: "after clear"))
        #expect(transcript.chapters == [])
        transcript.install(summary: Summary(text: "with chapters", chapters: generated))
        #expect(transcript.chapters == generated)

        transcript.removeSummary()
        #expect(transcript.summary == nil)
        #expect(transcript.chapters == generated)

        var older = Transcript(segments: [], language: "en", modelName: "stub", summary: Summary(text: "saved", chapters: generated))
        older.removeSummary()
        #expect(older.chapters == generated)
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

    @Test("dismissing an error with no transcript returns to the library")
    func dismissWithoutTranscriptGoesIdle() {
        let model = makeModel()
        model.transcript = nil
        model.phase = .failed(message: "boom")

        model.dismissError()

        #expect(model.phase == .idle)
    }

    @Test("an installed mock counts as available so AI affordances stay live in test mode")
    func mockKeepsAIAvailable() async {
        await withOnDeviceMock(MockLanguageModelResponse(text: "ok")) {
            #expect(await LanguageModelFactory.onDeviceAvailability().isAvailable)
        }
    }
}
