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

/// A capture that refuses to start, the way ScreenCaptureKit does without Screen Recording permission.
private struct RefusedCapture: LiveAudioSource {
    func start() async throws { throw ParolaError.captureUnavailable("ScreenCaptureKit unavailable: declined") }
    func prepare() async throws -> URL { URL(fileURLWithPath: "/dev/null") }
    func cancel() async {}
}

@MainActor
@Suite("Refused recording permission")
struct RefusedPermissionTests {
    @Test("a system-audio take refused for Screen Recording offers that pane, and only then")
    func screenRecordingRefusalOffersItsPane() {
        let refused = ParolaError.captureUnavailable("ScreenCaptureKit unavailable: declined")
        #expect(AppModel.missingPermission(for: refused, source: .systemAudio, screenRecordingGranted: false) == .screenRecording)
        #expect(AppModel.missingPermission(for: refused, source: .systemAudio, screenRecordingGranted: true) == nil)
        #expect(AppModel.missingPermission(for: refused, source: .microphone, screenRecordingGranted: false) == nil)
    }

    @Test("a take that couldn't start for want of Screen Recording leaves its Stage a way to the pane")
    func refusedTakeKeepsThePermission() async {
        let model = makeRecordingModel("refused-screen-recording")
        model.useStreaming = false
        model.screenRecordingCheck = { false }
        model.takeCaptureOverride = { _ in RefusedCapture() }

        model.startRecording(source: .systemAudio)

        await waitUntil {
            guard case .failed = model.recording?.state else { return false }
            return true
        }
        #expect(model.recording?.missingPermission == .screenRecording)
    }
}

@Suite("Microphone access message")
struct MicrophoneAccessMessageTests {
    private func italianBundle() throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test("the microphone-off guidance is localized to Italian")
    func localizedToItalian() throws {
        let message = AppModel.microphoneAccessOffMessage(bundle: try italianBundle())
        #expect(message == "L'accesso al microfono è disattivato. Attivalo in Impostazioni di Sistema → Privacy e sicurezza → Microfono, poi avvia di nuovo la registrazione.")
    }

    @Test("the English guidance uses arrow separators, not chevrons")
    func englishUsesArrowSeparators() {
        let message = AppModel.microphoneAccessOffMessage()
        #expect(message == "Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone, then start recording again.")
        #expect(!message.contains("›"))
    }
}
