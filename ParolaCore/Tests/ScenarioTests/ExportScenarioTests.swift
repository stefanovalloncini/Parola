import Foundation
import Testing
import ScenarioKit

extension ScenarioSuite {
    @Suite("Export scenarios", .enabled(if: ScenarioSuite.backend == "mock"))
    struct Export {
        @Test("export writes each format to the queued destination")
        func exportsTranscriptFiles() async throws {
            let client = try ScenarioBridgeClient()
            try await client.connect()
            defer { Task { await client.close() } }

            _ = try await client.send("resetTestState")
            _ = try await client.send("selectModel", ["name": ScenarioSuite.installedModelID])
            _ = try await client.send("installMockTranscriber", ["engineID": "all", "response": [
                "segments": [
                    ["start": 0.0, "end": 1.5, "text": "Hello world."],
                    ["start": 1.5, "end": 4.0, "text": "This is Parola."],
                    ["start": 4.0, "end": 7.25, "text": "Goodbye."],
                ],
                "language": "en",
                "modelName": "openai_whisper-tiny",
            ]])

            let audioURL = try Self.makeFixtureWav()
            defer { try? FileManager.default.removeItem(at: audioURL) }
            _ = try await client.send("transcribeFile", ["path": audioURL.path])
            let ready = try await client.send("waitForPhase", ["phase": "ready", "timeoutMs": 10000])
            #expect(ready["matched"]?.boolValue == true)

            let goldenDir = Self.goldenDir()
            for format in ["txt", "srt", "vtt", "md", "csv", "html"] {
                let out = FileManager.default.temporaryDirectory
                    .appendingPathComponent("parola-export-\(UUID().uuidString).\(format)")
                try? FileManager.default.removeItem(at: out)

                _ = try await client.send("queueSaveDestination", ["path": out.path])
                _ = try await client.send("exportTranscript", ["format": format])

                // performExport writes the file in a background Task with no completion
                // signal — poll the filesystem until the atomic write lands.
                let wrote = try await ScenarioSuite.poll { FileManager.default.fileExists(atPath: out.path) ? true : nil } ?? false
                #expect(wrote, "export never wrote \(format) to \(out.path)")

                // md/html embed a title derived from the source filename; the fixture name is a
                // random UUID, so fold it back to the snapshot's placeholder before the byte-match.
                let sourceTitle = audioURL.deletingPathExtension().lastPathComponent
                let written = try String(contentsOf: out, encoding: .utf8)
                    .replacingOccurrences(of: sourceTitle, with: "Transcript")
                let golden = try String(
                    contentsOf: goldenDir.appendingPathComponent("snapshot.\(format)"),
                    encoding: .utf8
                )
                #expect(written == golden, "\(format) export did not byte-match snapshot.\(format)")

                try? FileManager.default.removeItem(at: out)
            }

            _ = try await client.send("clearMocks", ["scope": "all"])
        }

        private static func goldenDir() -> URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Tests/ParolaCoreTests/Resources/expected", isDirectory: true)
        }

        private static func makeFixtureWav() throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("parola-export-fixture-\(UUID().uuidString).wav")
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
