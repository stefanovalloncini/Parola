import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Card metadata generation", .serialized)
struct CardMetadataTests {
    private func makeModel(_ defaults: UserDefaults) -> AppModel {
        AppModel(skipBootstrap: true, defaults: defaults, libraryURL: makeTempLibraryURL("cardmetadata"))
    }

    @Test("defaults: generation and both display toggles are on")
    func defaultsOn() {
        let model = makeModel(temporaryDefaults())
        #expect(model.generatesCardMetadata)
        #expect(model.showAITitles)
        #expect(model.showAISummaries)
    }

    /// Takes the store's lease, installs the mock, runs the body and clears it whether the body
    /// returns or throws. The store is process-global while swift-testing runs suites in parallel.
    private func withOnDeviceMock<T: Sendable>(
        _ text: String,
        _ body: @MainActor () async throws -> T
    ) async rethrows -> T {
        try await MockLanguageModelStore.shared.withLease {
            await MockLanguageModelStore.shared.clear()
            await MockLanguageModelStore.shared.install(
                provider: .foundation,
                response: MockLanguageModelResponse(text: text)
            )
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

    @Test("a finished transcript gets an AI title and summary from the mock model")
    func generatesOnCompletion() async throws {
        try await withOnDeviceMock("Piano vendite\nRiepilogo delle quote per canale.") {
            let model = makeModel(temporaryDefaults())
            let entry = try await model.library.add(transcript: longTranscript(), audioSource: nil, category: .transcription, source: .file)
            await model.generateCardMetadata(for: entry.id, transcript: longTranscript())
            let reloaded = try #require(model.libraryEntry(id: entry.id))
            #expect(reloaded.aiTitle == "Piano vendite")
            #expect(reloaded.shortSummary == "Riepilogo delle quote per canale.")
        }
    }

    @Test("a card lands on its row without listing the library again")
    func cardPatchesTheRow() async throws {
        let model = makeModel(temporaryDefaults())
        await model.libraryRefreshTask?.value
        model.cardMetadataOperation = { _ in CardMetadata(title: "Piano vendite", summary: "Quote per canale.") }
        let entry = try await model.library.add(transcript: longTranscript(), audioSource: nil, category: .transcription, source: .file)
        model.landLibraryEntry(entry)
        let refreshes = model.libraryRefreshes

        await model.generateCardMetadata(for: entry.id, transcript: longTranscript())

        #expect(model.libraryEntry(id: entry.id)?.aiTitle == "Piano vendite")
        #expect(model.libraryEntry(id: entry.id)?.shortSummary == "Quote per canale.")
        #expect(model.libraryRefreshes == refreshes)
    }

    @Test("generation is skipped when the toggle is off")
    func skippedWhenOff() async throws {
        try await withOnDeviceMock("T\nS") {
            let model = makeModel(temporaryDefaults())
            model.generatesCardMetadata = false
            let entry = try await model.library.add(transcript: longTranscript(), audioSource: nil, category: .transcription, source: .file)
            await model.generateCardMetadata(for: entry.id, transcript: longTranscript())
            let stored = try await model.library.load(entry.id)
            #expect(stored.entry.aiTitle == nil)
            #expect(stored.entry.shortSummary == nil)
        }
    }

    @Test("regenerateCardMetadata bypasses the generation toggle")
    func regenerateBypassesToggle() async throws {
        try await withOnDeviceMock("Piano vendite\nRiepilogo delle quote per canale.") {
            let model = makeModel(temporaryDefaults())
            model.generatesCardMetadata = false
            let entry = try await model.library.add(transcript: longTranscript(), audioSource: nil, category: .transcription, source: .file)
            model.selectedEntryID = entry.id
            model.transcript = longTranscript()

            model.regenerateCardMetadata()
            var written = false
            for _ in 0..<200 {
                if try await model.library.load(entry.id).entry.aiTitle != nil { written = true; break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(written)
            let reloaded = try await model.library.load(entry.id).entry
            #expect(reloaded.aiTitle == "Piano vendite")
            #expect(reloaded.shortSummary == "Riepilogo delle quote per canale.")
        }
    }

    @Test("toggling AI titles bumps the library version so rows redraw")
    func toggleBumpsVersion() {
        let model = makeModel(temporaryDefaults())
        let before = model.libraryVersion
        model.showAITitles = false
        #expect(model.libraryVersion == before + 1)
    }

    @Test("blank custom prompts trim to nil so the built-in instructions are used")
    func resolvedPromptTrimsBlankToNil() {
        #expect(AppModel.resolvedPrompt("") == nil)
        #expect(AppModel.resolvedPrompt("   \n\t ") == nil)
        #expect(AppModel.resolvedPrompt("  Mention the client's name.  ") == "  Mention the client's name.  ")
    }

    private func longTranscript() -> Transcript {
        Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 9, text: String(repeating: "vendite per canale ", count: 6))],
            language: "it", modelName: "m", sourceURL: URL(fileURLWithPath: "/tmp/a.wav")
        )
    }
}
