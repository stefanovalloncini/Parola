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

            if ScenarioSuite.isReal {
                // Real path: no mocks. The dictation inserter is CapturingTextInserter in
                // test mode, so this needs only Microphone TCC (no Accessibility). The
                // spoken fixture loops into the mic via BlackHole (set up by scenarios.sh).
                _ = try await client.send("startDictation")
                let listening = try await client.send("waitForDictationState", ["state": "listening", "timeoutMs": 5000])
                #expect(listening["matched"]?.boolValue == true)

                try await Task.sleep(for: .seconds(5))
                _ = try await client.send("stopDictation")

                // Poll the capture buffer; real decode + foundation-LLM cleanup runs after
                // the dictationEnabled flag flips, so give it a generous window.
                var inserted: String?
                for _ in 0..<150 {
                    let result = try await client.send("getLastInsertedText")
                    if let text = result["lastText"]?.stringValue, !text.isEmpty {
                        inserted = text
                        break
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                // Loose assert: the inserted text is the live LLM cleanup of real speech,
                // so only require it to be non-empty.
                #expect((inserted ?? "").isEmpty == false, "real dictation inserted nothing")
            } else {
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

        // Mock-only: --real exercises the live foundation-LLM cleanup inside the
        // passthrough test above, so this scripted-cleanup variant skips under --real.
        @Test("dictation inserts the LLM-cleaned text", .enabled(if: ScenarioSuite.backend == "mock"))
        func insertsCleanedText() async throws {
            let client = try ScenarioBridgeClient()
            try await client.connect()
            defer { Task { await client.close() } }

            _ = try await client.send("resetTestState")
            _ = try await client.send("selectModel", ["name": "openai_whisper-tiny"])
            _ = try await client.send("installMockStreamingTranscriber", ["response": [
                "partials": ["buy", "buy milk", "buy milk and eggs"],
                "segments": [["start": 0, "end": 2, "text": "buy milk and eggs"]],
                "delayMs": 300,
            ]])
            _ = try await client.send("installMockLanguageModel", [
                "provider": "foundation",
                "response": ["text": "Buy milk and eggs."],
            ])
            _ = try await client.send("setDictationCleanupPromptID", ["id": "00000000-0000-0000-0000-000000000001"])

            _ = try await client.send("startDictation")
            let listening = try await client.send("waitForDictationState", ["state": "listening", "timeoutMs": 5000])
            #expect(listening["matched"]?.boolValue == true)

            try await Task.sleep(for: .seconds(1))
            _ = try await client.send("stopDictation")

            var inserted: String?
            for _ in 0..<50 {
                let result = try await client.send("getLastInsertedText")
                if let text = result["lastText"]?.stringValue, !text.isEmpty {
                    inserted = text
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(inserted == "Buy milk and eggs.")

            _ = try await client.send("clearMocks", ["scope": "all"])
        }
    }
}
