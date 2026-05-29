import Foundation
import Testing
import ScenarioKit

extension ScenarioSuite {
    @Suite("YouTube scenarios", .enabled(if: ScenarioSuite.backend == "mock"))
    struct YouTube {
        @Test("transcribes a YouTube URL without network")
        func transcribesWithoutNetwork() async throws {
            let client = try ScenarioBridgeClient()
            try await client.connect()
            defer { Task { await client.close() } }

            let audioURL = try Self.makeFixtureWav()
            defer { try? FileManager.default.removeItem(at: audioURL) }

            _ = try await client.send("resetTestState")
            _ = try await client.send("selectModel", ["name": "openai_whisper-tiny"])
            _ = try await client.send("installMockTranscriber", ["engineID": "all", "response": [
                "segments": [
                    ["start": 0.0, "end": 2.0, "text": "mock youtube transcript"],
                ],
                "language": "en",
                "modelName": "openai_whisper-tiny",
            ]])
            _ = try await client.send("installMockMediaFetcher", ["fixturePath": audioURL.path])

            _ = try await client.send("transcribeYouTube", ["url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ"])
            let ready = try await client.send("waitForPhase", ["phase": "ready", "timeoutMs": 10000])
            #expect(ready["matched"]?.boolValue == true)

            let transcript = try await client.send("getTranscript")
            #expect(transcript["text"]?.stringValue?.contains("mock youtube transcript") == true)

            _ = try await client.send("clearMocks", ["scope": "all"])
        }

        private static func makeFixtureWav() throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("parola-youtube-fixture-\(UUID().uuidString).wav")
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
            data.append(u16(1))                    // PCM
            data.append(u16(1))                    // mono
            data.append(u32(sampleRate))
            data.append(u32(sampleRate * 2))       // byte rate
            data.append(u16(2))                    // block align
            data.append(u16(16))                   // bits per sample
            data.append(Data("data".utf8))
            data.append(u32(dataBytes))
            data.append(Data(count: Int(dataBytes)))
            try data.write(to: url)
            return url
        }
    }
}
