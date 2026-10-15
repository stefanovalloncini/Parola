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

    @Test("captions on Apple Speech get the Apple Speech session and takes get the refusing one")
    func appleSpeechRouting() {
        MockStreamingTranscriberRegistry.shared.clear()
        let apple = AppleSpeechTranscriber.syntheticModelID
        #expect(StreamingTranscriberFactory.make(purpose: .captions, model: apple) is AppleSpeechCaptionSession)
        #expect(StreamingTranscriberFactory.make(purpose: .captions, model: "openai_whisper-tiny") is StreamingTranscriptionSession)
        #expect(StreamingTranscriberFactory.make(purpose: .captions) is StreamingTranscriptionSession)
        #expect(StreamingTranscriberFactory.make(purpose: .take, model: apple) is StreamingTranscriptionSession)
    }

    @Test("an installed mock still wins over the Apple Speech session")
    func mockBeatsAppleSpeech() {
        MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(partials: ["x"]))
        defer { MockStreamingTranscriberRegistry.shared.clear() }
        #expect(StreamingTranscriberFactory.make(purpose: .captions, model: AppleSpeechTranscriber.syntheticModelID) is MockStreamingTranscriber)
    }

    @Test("offline Apple Speech captions never reach the speech service")
    func offlineAppleSpeech() async {
        MockStreamingTranscriberRegistry.shared.clear()
        StreamingTranscriberFactory.useOfflineAppleSpeechCaptions(true)
        defer { StreamingTranscriberFactory.useOfflineAppleSpeechCaptions(false) }
        let session = StreamingTranscriberFactory.make(purpose: .captions, model: AppleSpeechTranscriber.syntheticModelID)
        do {
            _ = try await session.start(options: TranscriptionOptions(model: AppleSpeechTranscriber.syntheticModelID, language: "en"), speakerLabeler: nil, downloadProgress: nil)
            Issue.record("an offline session started")
        } catch let ParolaError.unsupportedForEngine(text) {
            #expect(text == FixedFailureText.appleSpeechCouldNotStart)
        } catch {
            Issue.record("unexpected \(error)")
        }
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

    @Test("the factory keeps the device UID overload and takes a source")
    func factoryRouting() {
        MockStreamingTranscriberRegistry.shared.clear()
        let byDevice = StreamingTranscriberFactory.make(deviceUID: "usb")
        #expect((byDevice as? StreamingTranscriptionSession)?.source == .microphone(deviceUID: "usb"))
        #expect((byDevice as? StreamingTranscriptionSession)?.deviceUID == "usb")

        let bySource = StreamingTranscriberFactory.make(deviceUID: "usb", source: .app(bundleID: "us.zoom.xos"))
        #expect((bySource as? StreamingTranscriptionSession)?.source == .app(bundleID: "us.zoom.xos"))
        #expect((bySource as? StreamingTranscriptionSession)?.deviceUID == nil)
    }

    @Test("a mock transcriber records the source it was made with")
    func mockRecordsSource() {
        MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(partials: ["x"]))
        defer { MockStreamingTranscriberRegistry.shared.clear() }
        let made = StreamingTranscriberFactory.make(source: .systemAudio) as? MockStreamingTranscriber
        _ = StreamingTranscriberFactory.make(deviceUID: "usb")
        #expect(made?.source == .systemAudio)
        #expect(MockStreamingTranscriberRegistry.shared.madeSources() == [.systemAudio, .microphone(deviceUID: "usb")])
    }
}
