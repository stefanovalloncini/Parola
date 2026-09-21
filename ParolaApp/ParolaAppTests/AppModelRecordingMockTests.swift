import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

extension TranscriberMockSuites {
    @MainActor
    @Suite("Mic recording honours the installed audio mock", .serialized)
    struct AppModelRecordingMockTests {

        private func makeModel() -> AppModel {
            AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("recording"))
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

        @Test("a non-WhisperKit model takes the capture path instead of failing to stream")
        func captureWhenEngineCannotStream() async {
            await MockAudioSourceRegistry.shared.clear()
            let model = makeModel()
            model.useStreaming = true
            model.selectedModel = "nvidia_parakeet-tdt-0.6b-v2"

            #expect(await model.shouldUseStreamingMic() == false)
        }

        @Test("streaming off always takes the capture path regardless of mocks")
        func captureWhenStreamingOff() async {
            await MockAudioSourceRegistry.shared.clear()
            let model = makeModel()
            model.useStreaming = false

            #expect(await model.shouldUseStreamingMic() == false)
        }

        @Test("streaming finish clears live buffers and installs the transcript")
        func finishedClearsLiveSegments() async {
            let model = makeModel()
            model.liveSegments = [TranscriptSegment(id: 0, start: 0, end: 1, text: "live")]
            model.livePartialText = "partial"
            let final = Transcript(segments: [TranscriptSegment(id: 0, start: 0, end: 1, text: "done")], language: "en", modelName: "mock")
            model.selectedEntryID = "stale-entry"
            await model.handleStreamingEvent(.finished(final))
            #expect(model.selectedEntryID == nil)
            #expect(model.liveSegments.isEmpty)
            #expect(model.livePartialText.isEmpty)
            #expect(model.transcript?.segments.first?.text == "done")
            #expect(model.phase == .ready)
        }

        private struct StubAudioSource: AudioSource {
            func prepare() async throws -> URL { URL(fileURLWithPath: "/tmp/stub-\(UUID()).wav") }
            func cancel() async {}
            func estimatedDuration() async -> Double? { nil }
        }

        @Test("stop hands off the live source synchronously so a second stop is a no-op")
        func doubleStopSingleHandoff() {
            let model = makeModel()
            model.liveSource = StubAudioSource()
            model.phase = .recording(source: .microphone)
            model.stopRecordingAndTranscribe()
            #expect(model.liveSource == nil)
        }
    }
}
