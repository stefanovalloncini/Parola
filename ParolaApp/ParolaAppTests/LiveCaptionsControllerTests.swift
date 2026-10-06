import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

extension TranscriberMockSuites {
    @MainActor
    @Suite("Live captions controller", .serialized)
    struct LiveCaptionsControllerTests {

        @Test("a line confirmed while the translate flip stops the session stays in the history", .timeLimit(.minutes(1)))
        func flipKeepsTheLinesTheStopDrains() async throws {
            try await withMocksCleared(.streaming) {
                MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "the last line before the flip")],
                    partials: ["the last", "the last line"],
                    delayMs: 300
                ))
                let controller = LiveCaptionsController(showsPanel: false)
                await controller.start(options: TranscriptionOptions())
                await waitUntil { !controller.state.partial.isEmpty }
                #expect(controller.state.history.isEmpty, "the line should still be in flight when the flip starts")

                await controller.setTranslate(true)

                #expect(controller.state.history.first == "the last line before the flip")
                #expect(controller.state.isActive)
                await controller.stop()
            }
        }

        @Test("a failure keeps the panel up with its reason, and Try Again starts over", .timeLimit(.minutes(1)))
        func failureStaysOnThePanel() async throws {
            try await withMocksCleared(.streaming) {
                MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(
                    failure: MockTranscriberFailure(code: .transcriptionFailed, message: "The microphone stopped.")
                ))
                let controller = LiveCaptionsController(showsPanel: false)
                await controller.start(options: TranscriptionOptions())
                await waitUntil { controller.state.error != nil }

                #expect(controller.state.error == "The microphone stopped.")
                #expect(controller.isPanelShown, "the panel went away without a word")
                #expect(!controller.state.isActive)

                MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(partials: ["again"], delayMs: 300))
                await controller.tryAgain()
                #expect(controller.state.isActive)
                #expect(controller.state.error == nil)
                await controller.stop()
                #expect(!controller.isPanelShown)
            }
        }

        @Test("closing a failed panel hides it", .timeLimit(.minutes(1)))
        func closingAFailedPanel() async throws {
            try await withMocksCleared(.streaming) {
                MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(
                    failure: MockTranscriberFailure(code: .transcriptionFailed, message: "The microphone stopped.")
                ))
                let controller = LiveCaptionsController(showsPanel: false)
                await controller.start(options: TranscriptionOptions())
                await waitUntil { controller.state.error != nil }

                controller.closeFailure()

                #expect(!controller.isPanelShown)
            }
        }

        @Test("closing the panel stops the microphone", .timeLimit(.minutes(1)))
        func closingThePanelStops() async throws {
            try await withMocksCleared(.streaming) {
                MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "a line")],
                    partials: ["a", "a line"],
                    delayMs: 300
                ))
                let controller = LiveCaptionsController(showsPanel: false)
                await controller.start(options: TranscriptionOptions())
                let panel = try #require(controller.panel)
                #expect(controller.state.isActive)

                panel.close()

                await waitUntil { !controller.state.isActive }
                await controller.stop()
            }
        }
    }
}
