import Foundation
import ParolaCore
import ParolaDictation
import ParolaSpeech
import Testing
@testable import Parola
import ParolaTestSupport

extension TranscriberMockSuites {
    @MainActor
    @Suite("Read Aloud and live captions", .serialized)
    struct ReadAloudCaptionsTests {
        @Test("turning live captions on pauses the reading before captions start", .timeLimit(.minutes(1)))
        func toggleYields() async throws {
            try await withMocksCleared(.streaming) {
                MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(partials: ["live"], delayMs: 300))
                let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("read-captions"))
                let captions = LiveCaptionsController(showsPanel: false)
                model.liveCaptions = captions
                model.transcript = Transcript(
                    segments: (0..<4).map { TranscriptSegment(id: $0, start: Double($0), end: Double($0) + 1, text: "Segment \($0) says something.") },
                    language: "en", modelName: "stub"
                )
                model.phase = .ready
                await model.readAloud(ReadAloudRequest(kind: .transcript))
                await waitUntil { model.readAloud.state == .reading }

                model.toggleLiveCaptions()

                #expect(model.readAloud.state == .paused(.captions))
                await waitUntil { captions.isActive }
                await captions.stop()
                await model.stopReading()
            }
        }
    }
}
