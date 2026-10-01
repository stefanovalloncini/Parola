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
                let expected = marker.map { AutomationValue.double($0) }
                #expect(marker != nil)
                #expect(marked["marker"] == expected)

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

        private func toneWAV() throws -> URL {
            let rate = 16_000
            var data = Data()
            func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            let samples = (0..<rate).map { Int16(16_000 * sin(2 * Double.pi * 220 * Double($0) / Double(rate))) }
            data.append(contentsOf: Array("RIFF".utf8)); le32(UInt32(36 + samples.count * 2)); data.append(contentsOf: Array("WAVE".utf8))
            data.append(contentsOf: Array("fmt ".utf8)); le32(16); le16(1); le16(1); le32(UInt32(rate)); le32(UInt32(rate * 2)); le16(2); le16(16)
            data.append(contentsOf: Array("data".utf8)); le32(UInt32(samples.count * 2))
            for sample in samples { le16(UInt16(bitPattern: sample)) }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("parola-test-tone-\(UUID().uuidString).wav")
            try data.write(to: url)
            return url
        }

        @Test("a fixture's loudness reaches a streaming take that meters nothing of its own")
        func feedTakeLevels() async throws {
            let tone = try toneWAV()
            defer { try? FileManager.default.removeItem(at: tone) }
            try await withMocksCleared([.streaming, .audioSource]) {
                let model = makeRecordingModel("stage-bridge-feed")
                let server = try ParolaAutomationServer(model: model)
                let context = AutomationContext(model: model, server: server)
                let commands = Dictionary(uniqueKeysWithValues: server.mockCommands().map { ($0.name, $0) })
                let feed = try #require(commands["feedTakeLevels"])
                let args = try feed.validate(AutomationArgs(["fixturePath": .string(tone.path)]))

                var refused = false
                do {
                    _ = try await feed.handler(args, context)
                } catch is AutomationError {
                    refused = true
                }
                #expect(refused, "no take is metering yet")

                MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(partials: ["Quick note"], delayMs: 60_000))
                model.useStreaming = true
                model.selectedModel = "openai_whisper-tiny"
                model.startRecording(source: .microphone)
                let metering = await waitUntil { model.recordingLevelMeter != nil }
                #expect(metering)
                #expect(model.recordingLevelMeter?.lastSound == nil)

                _ = try await feed.handler(args, context)
                let heard = await waitUntil { model.recordingLevelMeter?.lastSound != nil }
                #expect(heard)
                model.cancelCurrentWork()
                withExtendedLifetime(server) {}
            }
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
