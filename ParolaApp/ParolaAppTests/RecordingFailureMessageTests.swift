import Foundation
import Testing
@testable import Parola
import ParolaCore

@Suite("Recording failure message")
struct RecordingFailureMessageTests {
    private func italianBundle() throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test("a denied system-audio capture shows the localized Screen Recording guidance")
    func deniedSystemAudioShowsGuidance() throws {
        let message = AppModel.recordingFailureMessage(
            for: ParolaError.captureUnavailable("ScreenCaptureKit unavailable: declined"),
            source: .systemAudio,
            screenRecordingGranted: false,
            bundle: try italianBundle()
        )
        #expect(message == "Parola ha bisogno del permesso Registrazione schermo per catturare l'audio di sistema. Apri Impostazioni di Sistema → Privacy e sicurezza → Registrazione schermo e concedi l'accesso a Parola, poi avvia di nuovo la registrazione.")
    }

    @Test("a system-audio capture failure with permission granted keeps the raw reason")
    func grantedSystemAudioFallsThrough() {
        let error = ParolaError.captureUnavailable("no display available for system audio capture")
        let message = AppModel.recordingFailureMessage(
            for: error,
            source: .systemAudio,
            screenRecordingGranted: true
        )
        #expect(message == error.localizedDescription)
    }

    @Test("a microphone capture failure is not mapped to the Screen Recording guidance")
    func microphoneFailureFallsThrough() {
        let error = ParolaError.captureUnavailable("boom")
        let message = AppModel.recordingFailureMessage(
            for: error,
            source: .microphone,
            screenRecordingGranted: false
        )
        #expect(message == error.localizedDescription)
    }

    @Test("a non-capture error still localizes through the transcription mapper")
    func nonCaptureErrorDelegates() throws {
        let message = AppModel.recordingFailureMessage(
            for: ParolaError.transcriptionFailed("formato non valido"),
            source: .systemAudio,
            screenRecordingGranted: false,
            bundle: try italianBundle()
        )
        #expect(message == "Trascrizione non riuscita: formato non valido")
    }
}
