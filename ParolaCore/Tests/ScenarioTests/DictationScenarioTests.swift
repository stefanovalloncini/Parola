import Foundation
import Testing
import ScenarioKit

extension ScenarioSuite {
    @Suite("Dictation scenarios")
    struct Dictation {
        @Test("dictation inserts the transcribed text")
        func insertsTranscribedText() async throws {
            let client = try ScenarioBridgeClient()
            try await client.connect()
            defer { Task { await client.close() } }

            _ = try await client.send("resetTestState")
            _ = try await client.send("selectModel", ["name": "openai_whisper-tiny"])
            _ = try await client.send("installMockStreamingTranscriber", ["response": [
                "partials": ["buy", "buy milk", "buy milk and eggs"],
                "segments": [["start": 0, "end": 2, "text": "buy milk and eggs"]],
                "delayMs": 600,
            ]])

            _ = try await client.send("startDictation")
            let listening = try await client.send("waitForDictationState", ["state": "listening", "timeoutMs": 5000])
            #expect(listening["matched"]?.boolValue == true)

            try await Task.sleep(for: .seconds(1))
            _ = try await client.send("stopDictation")

            // waitForDictationState only tracks the dictationEnabled flag, which flips
            // before the async cleanup+insertion finishes; poll the capture buffer instead.
            var inserted: String?
            for _ in 0..<50 {
                let result = try await client.send("getLastInsertedText")
                if let text = result["lastText"]?.stringValue, !text.isEmpty {
                    inserted = text
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(inserted == "Buy milk and eggs")

            _ = try await client.send("clearMocks", ["scope": "all"])
        }
    }
}
