import Foundation
import Testing
@testable import Parola
import ParolaCore

@Suite("Transcription failure message")
struct TranscriptionFailureMessageTests {
    private func italianBundle() throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test("a transcription failure shows the Italian prefix and keeps the reason")
    func localizesPrefixKeepingReason() throws {
        let message = AppModel.transcriptionFailureMessage(
            for: ParolaError.transcriptionFailed("formato non valido"),
            bundle: try italianBundle()
        )
        #expect(message == "Trascrizione non riuscita: formato non valido")
    }

    @Test("a non-transcription error keeps its own description")
    func nonTranscriptionErrorFallsThrough() {
        let error = ParolaError.invalidLanguage("zz")
        #expect(AppModel.transcriptionFailureMessage(for: error) == error.localizedDescription)
    }

    @Test("the error card drops the message's own prefix")
    func errorDetailDropsPrefix() {
        let message = AppModel.transcriptionFailureMessage(for: ParolaError.transcriptionFailed("the model could not read the audio"))
        #expect(AppModel.errorDetail(from: message) == "the model could not read the audio")
    }

    @Test("the Italian prefix is dropped from the Italian message")
    func errorDetailDropsItalianPrefix() throws {
        let bundle = try italianBundle()
        let message = AppModel.transcriptionFailureMessage(for: ParolaError.transcriptionFailed("formato non valido"), bundle: bundle)
        #expect(AppModel.errorDetail(from: message, bundle: bundle) == "formato non valido")
    }

    @Test("a message without the prefix is left alone")
    func errorDetailKeepsOtherMessages() {
        #expect(AppModel.errorDetail(from: "The disk is full.") == "The disk is full.")
    }
}
