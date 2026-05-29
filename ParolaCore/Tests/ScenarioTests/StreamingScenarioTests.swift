import Foundation
import Testing
import ScenarioKit

extension ScenarioSuite {
    @Suite("Streaming scenarios")
    struct Streaming {
    @Test("mic streaming renders scripted partials then finishes")
    func micStreaming() async throws {
        let client = try ScenarioBridgeClient()
        try await client.connect()
        defer { Task { await client.close() } }

        _ = try await client.send("resetTestState")
        _ = try await client.send("selectModel", ["name": "openai_whisper-tiny"])
        _ = try await client.send("installMockStreamingTranscriber", ["response": [
            "partials": ["one", "one two", "one two three"],
            "segments": [["start": 0, "end": 3, "text": "one two three"]],
            "delayMs": 300,
        ]])

        _ = try await client.send("startRecording", ["source": "microphone"])
        let recording = try await client.send("waitForPhase", ["phase": "recording", "timeoutMs": 5000])
        #expect(recording["matched"]?.boolValue == true)

        _ = try await client.send("stopRecording")
        let ready = try await client.send("waitForPhase", ["phase": "ready", "timeoutMs": 10000])
        #expect(ready["matched"]?.boolValue == true)

        let transcript = try await client.send("getTranscript")
        #expect(transcript["text"]?.stringValue?.contains("one two three") == true)

        _ = try await client.send("clearMocks", ["scope": "all"])
    }
    }
}
