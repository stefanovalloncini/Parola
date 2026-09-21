import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("Card metadata generation", .serialized)
struct CardMetadataTests {
    private func makeModel(_ defaults: UserDefaults? = nil) -> AppModel {
        AppModel(skipBootstrap: true, defaults: defaults ?? temporaryDefaults(), libraryURL: makeTempLibraryURL("cardmetadata"))
    }

    @Test("defaults: generation and both display toggles are on")
    func defaultsOn() {
        let model = makeModel(temporaryDefaults())
        #expect(model.generatesCardMetadata)
        #expect(model.showAITitles)
        #expect(model.showAISummaries)
    }

    @Test("a finished transcript gets an AI title and summary from the mock model")
    func generatesOnCompletion() async throws {
        await MockLanguageModelStore.shared.install(provider: .foundation, response: MockLanguageModelResponse(text: "Piano vendite\nRiepilogo delle quote per canale."))
        defer { Task { await MockLanguageModelStore.shared.clear() } }
        let model = makeModel(temporaryDefaults())
        let entry = try await model.library.add(transcript: longTranscript(), audioSource: nil, category: .transcription, source: .file)
        await model.generateCardMetadata(for: entry.id, transcript: longTranscript())
        let reloaded = try #require(model.libraryEntry(id: entry.id))
        #expect(reloaded.aiTitle == "Piano vendite")
        #expect(reloaded.shortSummary == "Riepilogo delle quote per canale.")
    }

    @Test("generation is skipped when the toggle is off")
    func skippedWhenOff() async throws {
        await MockLanguageModelStore.shared.install(provider: .foundation, response: MockLanguageModelResponse(text: "T\nS"))
        defer { Task { await MockLanguageModelStore.shared.clear() } }
        let model = makeModel(temporaryDefaults())
        model.generatesCardMetadata = false
        let entry = try await model.library.add(transcript: longTranscript(), audioSource: nil, category: .transcription, source: .file)
        await model.generateCardMetadata(for: entry.id, transcript: longTranscript())
        #expect(model.libraryEntry(id: entry.id)?.aiTitle == nil)
    }

    @Test("toggling AI titles bumps the library version so rows redraw")
    func toggleBumpsVersion() {
        let model = makeModel(temporaryDefaults())
        let before = model.libraryVersion
        model.showAITitles = false
        #expect(model.libraryVersion == before + 1)
    }

    private func longTranscript() -> Transcript {
        Transcript(
            segments: [TranscriptSegment(id: 0, start: 0, end: 9, text: String(repeating: "vendite per canale ", count: 6))],
            language: "it", modelName: "m", sourceURL: URL(fileURLWithPath: "/tmp/a.wav")
        )
    }
}
