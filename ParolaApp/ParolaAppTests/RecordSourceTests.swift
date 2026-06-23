import Testing
@testable import Parola

@MainActor
@Suite("RecordSource presentation")
struct RecordSourceTests {
    @Test("the microphone source uses the mic glyph")
    func microphoneIcon() {
        #expect(AppModel.RecordSource.microphone.systemImage == "mic.fill")
    }

    @Test("system audio does not borrow the microphone glyph")
    func systemAudioIsNotAMic() {
        let icon = AppModel.RecordSource.systemAudio.systemImage
        #expect(!icon.isEmpty)
        #expect(icon != "mic.fill")
    }

    @Test("the two sources are visually distinct")
    func sourcesHaveDistinctIcons() {
        #expect(AppModel.RecordSource.microphone.systemImage != AppModel.RecordSource.systemAudio.systemImage)
    }
}
