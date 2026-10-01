import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

// Closures inside #expect/#require arguments can share a symbol with a later closure in the same test (Swift 6.4); bind waits first.
extension TranscriberMockSuites {
    @MainActor
    @Suite("Stage bridge commands", .serialized)
    struct StageBridgeCommandsTests {
        private func run(_ server: ParolaAutomationServer, _ model: AppModel, _ name: String) async throws -> [String: AutomationValue] {
            let commands = Dictionary(uniqueKeysWithValues: server.recordingCommands().map { ($0.name, $0) })
            let command = try #require(commands[name])
            let context = AutomationContext(model: model, server: server)
            let reply = try await command.handler(try command.validate(AutomationArgs([:])), context)
            guard case .object(let fields) = reply else { throw AutomationError.precondition("\(name) did not reply with an object") }
            return fields
        }

        @Test("the bridge pauses, marks, resumes and discards the take on the Stage")
        func takeControls() async throws {
            try await withMocksCleared(.audioSource) {
                let model = makeRecordingModel("stage-bridge")
                let server = try ParolaAutomationServer(model: model)
                try await startFixtureTake(model)

                let paused = try await run(server, model, "pauseRecording")
                #expect(paused["paused"] == .bool(true))
                #expect(model.recording?.isPaused == true)

                let marked = try await run(server, model, "addRecordingMarker")
                let marker = model.recording?.markers.first
                #expect(marker != nil)
                #expect(marked["marker"] == marker.map { .double($0) })

                let resumed = try await run(server, model, "resumeRecording")
                #expect(resumed["resumed"] == .bool(true))
                #expect(model.recording?.state == .recording)

                let discarded = try await run(server, model, "discardRecording")
                #expect(discarded["discarded"] == .bool(true))
                #expect(model.recording == nil)
                let saved = await model.library.list()
                #expect(saved.isEmpty)
                withExtendedLifetime(server) {}
            }
        }

        @Test("with nothing recording the bridge's take controls change nothing")
        func nothingToControl() async throws {
            let model = makeRecordingModel("stage-bridge-idle")
            let server = try ParolaAutomationServer(model: model)
            let paused = try await run(server, model, "pauseRecording")
            let marked = try await run(server, model, "addRecordingMarker")
            let discarded = try await run(server, model, "discardRecording")
            #expect(paused["paused"] == .bool(false))
            #expect(marked["marker"] == .null)
            #expect(discarded["discarded"] == .bool(false))
            withExtendedLifetime(server) {}
        }

        @Test("outside test mode the take controls are refused")
        func testModeOnly() async throws {
            let model = AppModel(bootstrap: AppBootstrap(
                mode: .normal, library: makeTempLibraryURL("stage-bridge-normal"), defaultsOverride: temporaryDefaults(),
                sideEffects: [], filePicker: TestFilePicker(), clock: ContinuousClock()
            ))
            let server = try ParolaAutomationServer(model: model)
            for name in ["pauseRecording", "resumeRecording", "addRecordingMarker", "discardRecording"] {
                var refused = false
                do {
                    _ = try await run(server, model, name)
                } catch is AutomationError {
                    refused = true
                }
                #expect(refused, "\(name) ran outside test mode")
            }
            withExtendedLifetime(server) {}
        }
    }
}
