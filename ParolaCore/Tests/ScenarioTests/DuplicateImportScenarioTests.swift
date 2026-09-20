import Foundation
import Testing
import ScenarioKit

extension ScenarioSuite {
    @Suite("Duplicate import scenarios", .enabled(if: ScenarioSuite.backend == "mock"))
    struct DuplicateImport {
        @Test("the same file dropped twice offers the entry already in the library")
        func secondImportOffersTheExistingEntry() async throws {
            let client = try ScenarioBridgeClient()
            try await client.connect()
            defer { Task { await client.close() } }

            _ = try await client.send("resetTestState")
            _ = try await client.send("selectModel", ["name": ScenarioSuite.installedModelID])
            _ = try await client.send("installMockTranscriber", ["engineID": "all", "response": [
                "segments": [["start": 0.0, "end": 1.5, "text": "Same recording, twice."]],
                "language": "en",
                "modelName": "openai_whisper-tiny",
            ]])

            let audioURL = try Self.makeFixtureWav()
            defer { try? FileManager.default.removeItem(at: audioURL) }

            _ = try await client.send("transcribeFile", ["path": audioURL.path])
            let firstRun = try await client.send("waitForPhase", ["phase": "ready", "timeoutMs": 20000])
            #expect(firstRun["matched"]?.boolValue == true)

            var firstEntryID: String?
            for _ in 0..<40 {
                let entries = try await client.send("listEntries", ["limit": 10])
                if let first = entries.arrayValue?.first, let id = first["id"]?.stringValue {
                    firstEntryID = id
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            let existingID = try #require(firstEntryID, "the first run never reached the library")

            _ = try await client.send("transcribeFile", ["path": audioURL.path])
            let prompted = try await client.send("waitForDuplicateImport", ["open": true, "timeoutMs": 15000])
            #expect(prompted["matched"]?.boolValue == true)

            let sheet = try await client.send("getDuplicateImport")
            #expect(sheet["open"]?.boolValue == true)
            #expect(sheet["entryID"]?.stringValue == existingID)
            #expect(sheet["modelName"]?.stringValue == "openai_whisper-tiny")
            #expect(sheet["file"]?.stringValue == audioURL.path)

            _ = try await client.send("resolveDuplicateImport", ["choice": "openExisting"])
            let closed = try await client.send("waitForDuplicateImport", ["open": false, "timeoutMs": 5000])
            #expect(closed["matched"]?.boolValue == true)

            let afterOpen = try await client.send("listEntries", ["limit": 10])
            #expect(afterOpen.arrayValue?.count == 1, "Open Existing must not add a second bundle")

            // A second model on the same audio: the two rows must be tellable apart afterwards.
            _ = try await client.send("installMockTranscriber", ["engineID": "all", "response": [
                "segments": [["start": 0.0, "end": 1.5, "text": "Same recording, twice."]],
                "language": "en",
                "modelName": "apple-speech-analyzer",
            ]])
            _ = try await client.send("transcribeFile", ["path": audioURL.path])
            _ = try await client.send("waitForDuplicateImport", ["open": true, "timeoutMs": 15000])
            _ = try await client.send("resolveDuplicateImport", ["choice": "transcribeAgain"])
            let secondRun = try await client.send("waitForPhase", ["phase": "ready", "timeoutMs": 20000])
            #expect(secondRun["matched"]?.boolValue == true)

            var entries: [JSONValue] = []
            for _ in 0..<40 {
                entries = (try await client.send("listEntries", ["limit": 10])).arrayValue ?? []
                if entries.count == 2 { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(entries.count == 2, "Transcribe Again must write a second bundle")
            let models = Set(entries.compactMap { $0["modelName"]?.stringValue })
            #expect(models == ["openai_whisper-tiny", "apple-speech-analyzer"])
            #expect(Set(entries.compactMap { $0["title"]?.stringValue }).count == 1)

            _ = try await client.send("clearMocks", ["scope": "all"])
        }

        private static func makeFixtureWav() throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("parola-duplicate-fixture-\(UUID().uuidString).wav")
            let sampleRate: UInt32 = 16000
            let samples: UInt32 = 1600
            let dataBytes = samples * 2
            var data = Data()
            func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
            func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            ascii("RIFF"); le32(36 + dataBytes); ascii("WAVE")
            ascii("fmt "); le32(16); le16(1); le16(1)
            le32(sampleRate); le32(sampleRate * 2); le16(2); le16(16)
            ascii("data"); le32(dataBytes)
            data.append(Data(count: Int(dataBytes)))
            try data.write(to: url)
            return url
        }
    }
}
