import Testing
@testable import ParolaCore

@Suite("Streaming transcriber factory", .serialized)
struct StreamingTranscriberFactoryTests {
    @Test("returns mock when one is installed, real session otherwise")
    func selectsBackend() {
        MockStreamingTranscriberRegistry.shared.clear()
        let real = StreamingTranscriberFactory.make()
        #expect(real is StreamingTranscriptionSession)
        MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(partials: ["x"]))
        let mock = StreamingTranscriberFactory.make()
        #expect(mock is MockStreamingTranscriber)
        MockStreamingTranscriberRegistry.shared.clear()
    }

    @Test("a device UID reaches the session it builds")
    func deviceUIDReachesSession() {
        MockStreamingTranscriberRegistry.shared.clear()
        let session = StreamingTranscriberFactory.make(deviceUID: "test-uid")
        #expect((session as? StreamingTranscriptionSession)?.deviceUID == "test-uid")
    }

    @Test("persistAudio reaches the session it builds and defaults off")
    func persistAudioReachesSession() {
        MockStreamingTranscriberRegistry.shared.clear()
        let recording = StreamingTranscriberFactory.make(persistAudio: true)
        #expect((recording as? StreamingTranscriptionSession)?.persistAudio == true)
        let captions = StreamingTranscriberFactory.make()
        #expect((captions as? StreamingTranscriptionSession)?.persistAudio == false)
    }

    @Test("unknown or missing device UIDs resolve to no capture device")
    func unknownDeviceUIDResolvesToNil() {
        #expect(StreamingTranscriptionSession.resolveInputDeviceID(uid: nil) == nil)
        #expect(StreamingTranscriptionSession.resolveInputDeviceID(uid: "") == nil)
        #expect(StreamingTranscriptionSession.resolveInputDeviceID(uid: "no-such-device-uid") == nil)
    }
}
