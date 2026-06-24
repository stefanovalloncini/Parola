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
}
