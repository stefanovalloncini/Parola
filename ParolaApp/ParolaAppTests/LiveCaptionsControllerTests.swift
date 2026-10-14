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

        @Test("Parakeet v2 captions in a language it doesn't speak fail at start, and Try Again fails the same way", .timeLimit(.minutes(1)))
        func parakeetRefusesAnotherLanguage() async throws {
            try await withMocksCleared(.streaming) {
                let controller = LiveCaptionsController(showsPanel: false)
                let options = TranscriptionOptions(model: "nvidia_parakeet-tdt-0.6b-v2", language: "it")
                await controller.start(options: options)
                await waitUntil { controller.state.error != nil }

                let reason = try #require(controller.state.error)
                #expect(reason.hasSuffix("does not support \"it\""), "\(reason)")
                #expect(controller.isPanelShown)
                #expect(!controller.state.isActive)

                await controller.tryAgain()
                await waitUntil { !controller.state.isActive && controller.state.error != nil }
                #expect(controller.state.error == reason)
            }
        }

        @Test("Translate to English on a running Parakeet session fails in the panel with the translation sentence", .timeLimit(.minutes(1)))
        func parakeetRefusesTranslateOnTheFlip() async throws {
            try await withMocksCleared(.streaming) {
                MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(partials: ["hello"], delayMs: 300))
                let controller = LiveCaptionsController(showsPanel: false)
                await controller.start(options: TranscriptionOptions(model: "nvidia_parakeet-tdt-0.6b-v3"))
                await waitUntil { !controller.state.partial.isEmpty }
                MockStreamingTranscriberRegistry.shared.clear()

                await controller.setTranslate(true)
                await waitUntil { controller.state.error != nil }

                let expected = FailureText.message(
                    for: ParolaError.unsupportedForEngine(FixedFailureText.cannotTranslate("Parakeet"))
                )
                #expect(controller.state.error == expected)
                #expect(!controller.state.isActive)
                #expect(controller.isPanelShown, "the panel stays so Retry is there")
            }
        }

        @Test("Retry uses the current translate setting, not the one the failed start had", .timeLimit(.minutes(1)))
        func retryAfterTranslateIsTurnedOff() async throws {
            try await withMocksCleared(.streaming) {
                let controller = LiveCaptionsController(showsPanel: false)
                controller.optionsProvider = { TranscriptionOptions(model: "nvidia_parakeet-tdt-0.6b-v3") }
                await controller.setTranslate(true)
                await controller.toggle(options: TranscriptionOptions(model: "nvidia_parakeet-tdt-0.6b-v3"))
                await waitUntil { controller.state.error != nil }
                #expect(controller.lastOptions?.task == .translate)

                await controller.setTranslate(false)
                MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(partials: ["again"], delayMs: 300))
                await controller.tryAgain()

                #expect(controller.state.isActive)
                #expect(controller.state.error == nil)
                #expect(controller.lastOptions?.task == .transcribe)
                await controller.stop()
            }
        }

        @Test("Retry starts on the model picked since the failure", .timeLimit(.minutes(1)))
        func retryAfterPickingWhisper() async throws {
            try await withMocksCleared(.streaming) {
                let controller = LiveCaptionsController(showsPanel: false)
                await controller.setTranslate(true)
                await controller.toggle(options: TranscriptionOptions(model: "nvidia_parakeet-tdt-0.6b-v3"))
                await waitUntil { controller.state.error != nil }

                await controller.setTranslate(false)
                controller.optionsProvider = { TranscriptionOptions(model: "openai_whisper-tiny") }
                MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(partials: ["again"], delayMs: 300))
                await controller.tryAgain()

                #expect(controller.state.isActive)
                #expect(controller.lastOptions?.model == "openai_whisper-tiny")
                await controller.stop()
            }
        }

        @Test("Retry with a model captions can't use shows the reason again instead of starting", .timeLimit(.minutes(1)))
        func retryWithAnUnavailableModel() async throws {
            try await withMocksCleared(.streaming) {
                MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(
                    failure: MockTranscriberFailure(code: .transcriptionFailed, message: "The capture stopped.")
                ))
                let controller = LiveCaptionsController(showsPanel: false)
                await controller.start(options: TranscriptionOptions())
                await waitUntil { controller.state.error != nil }

                controller.unavailableReason = { "Apple Speech can't show Live Captions. Pick a Whisper or Parakeet model." }
                await controller.tryAgain()

                #expect(controller.state.error == "Apple Speech can't show Live Captions. Pick a Whisper or Parakeet model.")
                #expect(!controller.state.isActive)
                #expect(controller.isPanelShown)
            }
        }

        @Test("a model that downloads shows its fraction until it has loaded", .timeLimit(.minutes(1)))
        func downloadFractionShows() async throws {
            try await withMocksCleared(.streaming) {
                let gate = MockTranscriberGate()
                MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(
                    partials: ["hello"], downloadFractions: [0.42], delayMs: 300, gate: gate
                ))
                let controller = LiveCaptionsController(showsPanel: false)
                await controller.start(options: TranscriptionOptions())
                await waitUntil { controller.state.downloadFraction == 0.42 }
                #expect(controller.state.isLoading)

                await gate.open()
                await waitUntil { !controller.state.isLoading }

                #expect(controller.state.downloadFraction == nil)
                await controller.stop()
            }
        }

        @Test("flipping Translate in the app reaches the controller for Parakeet, and still not for Apple Speech", .timeLimit(.minutes(1)))
        func appModelFlipReachesTheController() async throws {
            let model = AppModel(bootstrap: AppBootstrap(
                mode: .test, library: makeTempLibraryURL("captions-flip"), defaultsOverride: temporaryDefaults(),
                sideEffects: [], filePicker: TestFilePicker(), clock: ContinuousClock()
            ))
            let controller = LiveCaptionsController(showsPanel: false)
            model.liveCaptions = controller

            model.selectedModel = "nvidia_parakeet-tdt-0.6b-v3"
            model.liveCaptionsTranslate = true
            await waitUntil { controller.translateToEnglish }
            #expect(controller.translateToEnglish)

            model.liveCaptionsTranslate = false
            await waitUntil { !controller.translateToEnglish }
            model.selectedModel = "apple-speech-analyzer"
            model.liveCaptionsTranslate = true
            await Task.yield()
            #expect(!controller.translateToEnglish)
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

        @Test("a start passes its source to the transcriber, and Try Again keeps it", .timeLimit(.minutes(1)))
        func sourceSurvivesTryAgain() async throws {
            try await withMocksCleared(.streaming) {
                MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(
                    failure: MockTranscriberFailure(code: .transcriptionFailed, message: "The capture stopped.")
                ))
                let controller = LiveCaptionsController(showsPanel: false)
                await controller.start(options: TranscriptionOptions(), source: .app(bundleID: "us.zoom.xos"))
                await waitUntil { controller.state.error != nil }
                #expect(controller.source == .app(bundleID: "us.zoom.xos"))

                await controller.tryAgain()
                await waitUntil { MockStreamingTranscriberRegistry.shared.madeSources().count == 2 }

                #expect(MockStreamingTranscriberRegistry.shared.madeSources() == Array(repeating: .app(bundleID: "us.zoom.xos"), count: 2))
                await controller.stop()
            }
        }

        @Test("a source change while captions run restarts on it and keeps the lines", .timeLimit(.minutes(1)))
        func sourceChangeRestartsAndKeepsHistory() async throws {
            try await withMocksCleared(.streaming) {
                MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "said before the switch")],
                    partials: ["said", "said before"],
                    delayMs: 300
                ))
                let controller = LiveCaptionsController(showsPanel: false)
                await controller.start(options: TranscriptionOptions())
                await waitUntil { !controller.state.partial.isEmpty }

                await controller.setSource(.systemAudio)

                #expect(controller.source == .systemAudio)
                #expect(controller.state.isActive)
                #expect(controller.state.history.first == "said before the switch")
                #expect(MockStreamingTranscriberRegistry.shared.madeSources() == [.microphone(deviceUID: nil), .systemAudio])
                await controller.stop()
            }
        }

        @Test("two quick source changes during a slow stop end on the last one", .timeLimit(.minutes(1)))
        func twoQuickChangesEndOnTheLast() async throws {
            try await withMocksCleared(.streaming) {
                MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(
                    segments: [TranscriptSegmentSeed(start: 0, end: 1, text: "a line")],
                    partials: ["a", "a line"],
                    delayMs: 300
                ))
                let controller = LiveCaptionsController(showsPanel: false)
                await controller.start(options: TranscriptionOptions())
                await waitUntil { !controller.state.partial.isEmpty }

                let first = Task { await controller.setSource(.systemAudio) }
                await waitUntil { !controller.state.isActive }
                await controller.setSource(.app(bundleID: "us.zoom.xos"))
                await first.value

                #expect(controller.source == .app(bundleID: "us.zoom.xos"))
                #expect(MockStreamingTranscriberRegistry.shared.madeSources().last == .app(bundleID: "us.zoom.xos"))
                await controller.stop()
            }
        }

        @Test("a source picked while captions are off is the one the next start uses", .timeLimit(.minutes(1)))
        func sourcePickedWhileOff() async {
            let controller = LiveCaptionsController(showsPanel: false)
            await controller.setSource(.systemAudio)
            #expect(controller.source == .systemAudio)
            #expect(!controller.state.isActive)
        }

        @Test("a permission failure reads in the user's words and offers its pane", .timeLimit(.minutes(1)))
        func permissionFailureOffersSettings() async throws {
            try await withMocksCleared(.streaming) {
                MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(
                    failure: MockTranscriberFailure(code: .transcriptionFailed, message: FixedFailureText.systemAudioNotAllowed)
                ))
                let controller = LiveCaptionsController(showsPanel: false)
                await controller.start(options: TranscriptionOptions(), source: .systemAudio)
                await waitUntil { controller.state.error != nil }

                #expect(controller.failurePermission == .screenRecording)
                #expect(controller.state.error?.hasPrefix("Allow Parola in Screen & System Audio Recording") == true)

                MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(partials: ["again"], delayMs: 300))
                await controller.tryAgain()
                #expect(controller.failurePermission == nil)
                await controller.stop()
            }
        }

        @Test("the bridge sets the source and reports it with the state", .timeLimit(.minutes(1)))
        func bridgeSetsTheSource() async throws {
            let model = makeRecordingModel("captions-source-bridge")
            model.captionApps = CaptionAppList(
                observesChanges: false, ownBundleID: nil,
                runningApps: { [.init(bundleID: "com.apple.Music", name: "Music")] },
                audioBundleIDs: { ["com.apple.Music"] }
            )
            let server = try ParolaAutomationServer(model: model)
            let commands = Dictionary(uniqueKeysWithValues: server.recordingCommands().map { ($0.name, $0) })
            let context = AutomationContext(model: model, server: server)
            func call(_ name: String, _ args: [String: AutomationValue] = [:]) async throws -> [String: AutomationValue] {
                let command = try #require(commands[name])
                let reply = try await command.handler(try command.validate(AutomationArgs(args)), context)
                guard case .object(let fields) = reply else { throw AutomationError.precondition("\(name) did not reply with an object") }
                return fields
            }

            #expect(try await call("getLiveCaptionsState")["source"] == .string("microphone"))
            let set = try await call("setLiveCaptionsSource", ["source": .string("app:us.zoom.xos")])
            #expect(set["source"] == .string("app:us.zoom.xos"))
            #expect(model.liveCaptionsSource == .app(bundleID: "us.zoom.xos"))
            #expect(try await call("getLiveCaptionsState")["source"] == .string("app:us.zoom.xos"))
            await #expect(throws: AutomationError.self) {
                _ = try await call("setLiveCaptionsSource", ["source": .string("speakers")])
            }
            let apps = try await call("listCaptionApps")
            let expected = AutomationValue.array([.object([
                "bundleID": .string("com.apple.Music"), "name": .string("Music"), "isMeetingApp": .bool(false),
            ])])
            #expect(apps["apps"] == expected)
            withExtendedLifetime(server) {}
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
