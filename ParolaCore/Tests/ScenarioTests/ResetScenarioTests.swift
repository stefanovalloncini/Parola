import Foundation
import Testing
import ScenarioKit

extension ScenarioSuite {
    @Suite("Reset scenarios", .enabled(if: ScenarioSuite.backend == "mock"))
    struct Reset {
        @Test("resetTestState clears a failed phase back to idle")
        func resetClearsFailedPhase() async throws {
            let client = try ScenarioBridgeClient()
            try await client.connect()
            defer { Task { await client.close() } }

            _ = try await client.send("resetTestState")

            // Drive the app into a failed phase via a failing transcriber.
            _ = try await client.send("installMockTranscriber", [
                "engineID": "all",
                "failure": ["code": "transcriptionFailed", "message": "mock fail"],
            ])
            let audioURL = try Self.makeFixtureWav()
            defer { try? FileManager.default.removeItem(at: audioURL) }
            _ = try await client.send("transcribeFile", ["path": audioURL.path])

            var reachedFailed = false
            for _ in 0..<30 {
                if try await client.send("getState")["phase"]?.stringValue == "failed" {
                    reachedFailed = true; break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(reachedFailed, "precondition: app never reached the failed phase")

            _ = try await client.send("resetTestState")

            let state = try await client.send("getState")
            #expect(state["phase"]?.stringValue == "idle")
            #expect(state["hasTranscript"]?.boolValue == false)
        }

        @Test("resetTestState clears the loaded-entry selection")
        func resetClearsLoadedEntrySelection() async throws {
            let client = try ScenarioBridgeClient()
            try await client.connect()
            defer { Task { await client.close() } }

            _ = try await client.send("resetTestState")

            _ = try await client.send("installMockTranscriber", [
                "engineID": "all",
                "response": [
                    "segments": [["start": 0, "end": 1, "text": "loaded entry"]],
                    "language": "en",
                    "modelName": "mock",
                ],
            ])
            let audioURL = try Self.makeFixtureWav()
            defer { try? FileManager.default.removeItem(at: audioURL) }
            _ = try await client.send("transcribeFile", ["path": audioURL.path])
            _ = try await client.send("waitForPhase", ["phase": "ready", "timeoutMs": 15000])

            // The entry persists asynchronously after `ready`; poll until it is selected.
            var selectedBefore = ""
            for _ in 0..<20 {
                let loaded = try await client.send("waitForTranscriptLoaded", ["timeoutMs": 200])
                selectedBefore = loaded["observed"]?["selectedEntryID"]?.stringValue ?? ""
                if !selectedBefore.isEmpty { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(!selectedBefore.isEmpty, "precondition: an entry should be selected after a transcribe")

            _ = try await client.send("resetTestState")

            let after = try await client.send("waitForTranscriptLoaded", ["timeoutMs": 500])
            #expect(after["observed"]?["selectedEntryID"]?.stringValue == "")
            #expect(after["observed"]?["hasTranscript"]?.boolValue == false)
        }

        @Test("resetTestState tears down a running dictation session")
        func resetTearsDownDictation() async throws {
            let client = try ScenarioBridgeClient()
            try await client.connect()
            defer { Task { await client.close() } }

            _ = try await client.send("resetTestState")
            _ = try await client.send("selectModel", ["name": "openai_whisper-tiny"])
            _ = try await client.send("installMockStreamingTranscriber", [
                "response": ["segments": [], "partials": []],
            ])

            // Begin a dictation session (press → listening): the coordinator is now running.
            _ = try await client.send("startDictation")
            let listening = try await client.send("waitForDictationState", ["state": "listening", "timeoutMs": 5000])
            #expect(listening["matched"]?.boolValue == true, "precondition: dictation never reached listening")
            #expect(listening["observed"]?["running"]?.boolValue == true)

            // A reset must discard the in-flight session — not leak a running, listening
            // coordinator, which leaves the dictation HUD stuck on screen for the next test.
            _ = try await client.send("resetTestState")

            let after = try await client.send("waitForDictationState", ["state": "idle", "timeoutMs": 2000])
            #expect(after["observed"]?["running"]?.boolValue == false, "resetTestState left the dictation coordinator running")
            #expect(after["observed"]?["state"]?.stringValue == "idle", "resetTestState left dictation in a non-idle state")
        }

        private static func makeFixtureWav() throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("parola-reset-fixture-\(UUID().uuidString).wav")
            let sampleRate: UInt32 = 16000
            let samples: UInt32 = 1600
            let dataBytes = samples * 2
            var data = Data()
            func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
            func u16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
            data.append(Data("RIFF".utf8))
            data.append(u32(36 + dataBytes))
            data.append(Data("WAVE".utf8))
            data.append(Data("fmt ".utf8))
            data.append(u32(16))
            data.append(u16(1))
            data.append(u16(1))
            data.append(u32(sampleRate))
            data.append(u32(sampleRate * 2))
            data.append(u16(2))
            data.append(u16(16))
            data.append(Data("data".utf8))
            data.append(u32(dataBytes))
            data.append(Data(count: Int(dataBytes)))
            try data.write(to: url)
            return url
        }
    }
}
