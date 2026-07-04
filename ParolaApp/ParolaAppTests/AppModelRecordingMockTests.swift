import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("Mic recording honours the installed audio mock", .serialized)
struct AppModelRecordingMockTests {

    private func makeModel() -> AppModel {
        AppModel(skipBootstrap: true, defaults: UserDefaults(suiteName: "test-\(UUID())")!, libraryURL: makeTempLibraryURL("recording"))
    }

    @Test("with no mic mock and streaming on, the mic path uses the streaming session")
    func streamingWhenNoMock() async {
        await MockAudioSourceRegistry.shared.clear()
        let model = makeModel()
        model.useStreaming = true

        #expect(await model.shouldUseStreamingMic())
    }

    @Test("with a mic mock installed, the mic path skips streaming so the fixture reaches the transcriber")
    func captureWhenMicMockInstalled() async {
        let fixture = URL(fileURLWithPath: "/tmp/parola-fixture-\(UUID()).wav")
        await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)

        let model = makeModel()
        model.useStreaming = true

        #expect(await model.shouldUseStreamingMic() == false)
        await MockAudioSourceRegistry.shared.clear()
    }

    @Test("an 'all' mock also routes the mic path away from streaming")
    func captureWhenAllMockInstalled() async {
        let fixture = URL(fileURLWithPath: "/tmp/parola-fixture-\(UUID()).wav")
        await MockAudioSourceRegistry.shared.install(kind: nil, fixtureURL: fixture)

        let model = makeModel()
        model.useStreaming = true

        #expect(await model.shouldUseStreamingMic() == false)
        await MockAudioSourceRegistry.shared.clear()
    }

    @Test("the factory returns a fixture source for the mic when a mic mock is installed")
    func factoryReturnsFixtureForMic() async {
        let fixture = URL(fileURLWithPath: "/tmp/parola-fixture-\(UUID()).wav")
        await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)

        let source = await LiveAudioSourceFactory.makeMicrophone()

        #expect(source is FixtureAudioSource)
        await MockAudioSourceRegistry.shared.clear()
    }

    @Test("streaming off always takes the capture path regardless of mocks")
    func captureWhenStreamingOff() async {
        await MockAudioSourceRegistry.shared.clear()
        let model = makeModel()
        model.useStreaming = false

        #expect(await model.shouldUseStreamingMic() == false)
    }

    @Test("streaming finish clears live buffers and installs the transcript")
    func finishedClearsLiveSegments() {
        let model = makeModel()
        model.liveSegments = [TranscriptSegment(id: 0, start: 0, end: 1, text: "live")]
        model.livePartialText = "partial"
        let final = Transcript(segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "done")], language: "en", modelName: "mock")
        model.handleStreamingEvent(.finished(final))
        #expect(model.liveSegments.isEmpty)
        #expect(model.livePartialText.isEmpty)
        #expect(model.transcript?.segments.first?.text == "done")
        #expect(model.phase == .ready)
    }
}
