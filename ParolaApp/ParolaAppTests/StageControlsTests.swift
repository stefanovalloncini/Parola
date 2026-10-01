import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

// Closures inside #expect/#require arguments can share a symbol with a later closure in the same test (Swift 6.4); bind waits first.
extension TranscriberMockSuites {
    @MainActor
    @Suite("Stage controls", .serialized)
    struct StageControlsTests {
        @Test("Pause pauses a recording take and the same control resumes it")
        func togglePause() async throws {
            try await withMocksCleared(.audioSource) {
                let model = makeRecordingModel("stage-toggle")
                try await startFixtureTake(model)
                StageControls.togglePause(model)
                #expect(model.recording?.isPaused == true)
                StageControls.togglePause(model)
                #expect(model.recording?.state == .recording)
                model.cancelCurrentWork()
            }
        }

        @Test("a confirmed Discard deletes only the take it named")
        func discardNamesItsTake() async throws {
            try await withMocksCleared(.audioSource) {
                let model = makeRecordingModel("stage-discard")
                try await startFixtureTake(model)
                let takeID = try #require(model.recording?.takeID)

                let otherTake = await StageControls.discard(takeID + 1, model: model)
                #expect(!otherTake)
                #expect(model.recording?.state == .recording)

                let discarded = await StageControls.discard(takeID, model: model)
                #expect(discarded)
                let gone = await waitUntil { model.recording == nil }
                #expect(gone)
                let saved = await model.library.list()
                #expect(saved.isEmpty)
            }
        }

        @Test("a Discard answered after Stop leaves the stopped take alone")
        func discardAfterStop() async throws {
            try await withMocksCleared([.audioSource, .transcriber]) {
                let model = makeRecordingModel("stage-discard-stopped")
                await installMockTranscriber(segments: [(0, 0.3, "kept")])
                try await startFixtureTake(model)
                let takeID = try #require(model.recording?.takeID)
                model.stopRecordingAndTranscribe()

                await StageControls.discard(takeID, model: model)
                let landed = await landedEntry(model)
                #expect(landed != nil)
            }
        }
    }
}
