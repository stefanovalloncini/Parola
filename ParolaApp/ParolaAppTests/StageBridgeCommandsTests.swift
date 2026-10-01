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

        @Test("a held mock live take stays loading its model until the bridge lets it go")
        func heldStreamingStart() async throws {
            try await withMocksCleared([.streaming, .audioSource]) {
                await MockAudioSourceRegistry.shared.clear()
                let model = makeRecordingModel("stage-bridge-hold")
                let server = try ParolaAutomationServer(model: model)
                let context = AutomationContext(model: model, server: server)
                let commands = Dictionary(uniqueKeysWithValues: server.mockCommands().map { ($0.name, $0) })
                let install = try #require(commands["installMockStreamingTranscriber"])
                let release = try #require(commands["releaseMockStreamingStart"])
                let response: AutomationValue = .object([
                    "partials": .array([.string("Quick note")]), "downloadFractions": .array([.double(0.42)]), "delayMs": .int(60_000),
                ])
                _ = try await install.handler(
                    try install.validate(AutomationArgs(["response": response, "holdStart": .bool(true)])), context
                )
                model.useStreaming = true
                model.selectedModel = "openai_whisper-tiny"

                model.startRecording(source: .microphone)

                let preparing = await waitUntil { model.recording?.mode == .preparing("openai_whisper-tiny", 0.42) }
                #expect(preparing)
                try await Task.sleep(for: .milliseconds(300))
                #expect(model.recording?.mode == .preparing("openai_whisper-tiny", 0.42), "the model load stays held")
                let reply = try await release.handler(try release.validate(AutomationArgs([:])), context)
                #expect(reply == .object(["released": .bool(true)]))
                let recording = await waitUntil { model.recording?.state == .recording }
                #expect(recording)
                model.cancelCurrentWork()
                withExtendedLifetime(server) {}
            }
        }

        @Test("resetTestState lets go of a held live take's model load and takes the saved toast down")
        func resetLeavesNothingHeld() async throws {
            try await withMocksCleared([.streaming, .audioSource]) {
                let model = makeRecordingModel("stage-bridge-reset")
                let server = try ParolaAutomationServer(model: model)
                let context = AutomationContext(model: model, server: server)
                let mocks = Dictionary(uniqueKeysWithValues: server.mockCommands().map { ($0.name, $0) })
                let lifecycle = Dictionary(uniqueKeysWithValues: server.lifecycleCommands().map { ($0.name, $0) })
                let install = try #require(mocks["installMockStreamingTranscriber"])
                let reset = try #require(lifecycle["resetTestState"])
                _ = try await install.handler(try install.validate(AutomationArgs(["holdStart": .bool(true)])), context)
                #expect(server.heldStreamingStart != nil)
                model.takeSavedNotice = TakeSavedNotice(entryID: "E", category: .transcription)

                _ = try await reset.handler(try reset.validate(AutomationArgs([:])), context)

                #expect(server.heldStreamingStart == nil)
                #expect(model.takeSavedNotice == nil)
                withExtendedLifetime(server) {}
            }
        }

        @Test("resetTestState leaves the language-model mocks to a suite holding them until it is done")
        func resetWaitsForTheModelLease() async throws {
            try await withMocksCleared(.streaming) {
                let model = makeRecordingModel("stage-bridge-reset-lease")
                let server = try ParolaAutomationServer(model: model)
                let context = AutomationContext(model: model, server: server)
                let lifecycle = Dictionary(uniqueKeysWithValues: server.lifecycleCommands().map { ($0.name, $0) })
                let reset = try #require(lifecycle["resetTestState"])
                let arguments = try reset.validate(AutomationArgs([:]))
                let installed = FetchGate()
                let done = FetchGate()
                let holder = Task {
                    await MockLanguageModelStore.shared.withLease {
                        await MockLanguageModelStore.shared.install(provider: .ollama, response: MockLanguageModelResponse(text: "held"))
                        await installed.open()
                        await done.wait()
                        return await MockLanguageModelStore.shared.resolve(for: .ollama) != nil
                    }
                }
                await installed.wait()
                MockStreamingTranscriberRegistry.shared.install(MockTranscriberResponse(partials: ["held"]))
                let resetting = Task { @MainActor in try await reset.handler(arguments, context) }
                let reached = await waitUntil { MockStreamingTranscriberRegistry.shared.resolve() == nil }
                #expect(reached)
                await settle(for: .milliseconds(200))
                await done.open()
                let kept = await holder.value
                #expect(kept, "the reset cleared the store while a suite held it")
                _ = try await resetting.value
                let left = await MockLanguageModelStore.shared.withLease { await MockLanguageModelStore.shared.list() }
                #expect(left.isEmpty)
                withExtendedLifetime(server) {}
            }
        }

        @Test("outside test mode the take controls and the level feed are refused by the test-mode guard")
        func testModeOnly() async throws {
            let fixture = try makeTakeWAV("stage-bridge-normal")
            defer { try? FileManager.default.removeItem(at: fixture) }
            let model = AppModel(bootstrap: AppBootstrap(
                mode: .normal, library: makeTempLibraryURL("stage-bridge-normal"), defaultsOverride: temporaryDefaults(),
                sideEffects: [], filePicker: TestFilePicker(), clock: ContinuousClock()
            ))
            let server = try ParolaAutomationServer(model: model)
            let context = AutomationContext(model: model, server: server)
            let commands = Dictionary(uniqueKeysWithValues: (server.recordingCommands() + server.mockCommands()).map { ($0.name, $0) })
            let calls: [(name: String, args: [String: AutomationValue])] = [
                ("pauseRecording", [:]),
                ("resumeRecording", [:]),
                ("addRecordingMarker", [:]),
                ("discardRecording", [:]),
                ("feedTakeLevels", ["fixturePath": .string(fixture.path)]),
                ("releaseMockStreamingStart", [:]),
            ]
            for call in calls {
                let command = try #require(commands[call.name])
                var reason: String?
                do {
                    _ = try await command.handler(try command.validate(AutomationArgs(call.args)), context)
                } catch AutomationError.precondition(let message) {
                    reason = message
                }
                #expect(reason == "only available in --test-mode", "\(call.name) ran outside test mode")
            }
            withExtendedLifetime(server) {}
        }
    }
}
