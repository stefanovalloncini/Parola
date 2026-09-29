import Foundation
import Testing
import ScenarioKit

extension ScenarioSuite {
    @Suite("Streaming scenarios")
    struct Streaming {
    /// A take reads "recording" from the moment it's asked for, but captures only once its model is ready.
    private func waitForCapture(_ client: ScenarioBridgeClient, timeout: Duration) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let state = try await client.send("getState")
            if state["recordingStartedAt"]?.doubleValue != nil { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    @Test("mic streaming renders scripted partials then finishes")
    func micStreaming() async throws {
        let client = try ScenarioBridgeClient()
        try await client.connect()
        defer { Task { await client.close() } }

        _ = try await client.send("resetTestState")
        _ = try await client.send("selectModel", ["name": "openai_whisper-tiny"])

        if ScenarioSuite.isReal {
            // Real path: no mocks. scenarios.sh loops the spoken fixture into the mic
            // via BlackHole; let WhisperKit decode a few seconds, then assert loosely.
            _ = try await client.send("startRecording", ["source": "microphone"])
            let recording = try await client.send("waitForPhase", ["phase": "recording", "timeoutMs": 5000])
            #expect(recording["matched"]?.boolValue == true)
            // Loading the model can take a while on a cold start; the take counts only from its first audio.
            #expect(try await waitForCapture(client, timeout: .seconds(60)))

            try await Task.sleep(for: .seconds(5))
            _ = try await client.send("stopRecording")
            // Real WhisperKit load + decode is slow, so the readiness timeout is generous.
            let ready = try await client.send("waitForPhase", ["phase": "ready", "timeoutMs": 30000])
            #expect(ready["matched"]?.boolValue == true)

            // Loose smoke assert: non-empty transcript containing a fixture keyword tiny
            // transcribes reliably ("audio"/"model"); proper nouns mis-transcribe at this size.
            let transcript = try await client.send("getTranscript")
            let text = (transcript["text"]?.stringValue ?? "").lowercased()
            #expect(!text.isEmpty, "real streaming produced an empty transcript")
            #expect(["audio", "model"].contains { text.contains($0) },
                    "real streaming transcript missing expected fixture keyword: \(text)")
        } else {
            _ = try await client.send("installMockStreamingTranscriber", ["response": [
                "partials": ["one", "one two", "one two three"],
                "segments": [["start": 0, "end": 3, "text": "one two three"]],
                "delayMs": 300,
            ]])

            _ = try await client.send("startRecording", ["source": "microphone"])
            let recording = try await client.send("waitForPhase", ["phase": "recording", "timeoutMs": 5000])
            #expect(recording["matched"]?.boolValue == true)
            #expect(try await waitForCapture(client, timeout: .seconds(5)))

            _ = try await client.send("stopRecording")
            let ready = try await client.send("waitForPhase", ["phase": "ready", "timeoutMs": 10000])
            #expect(ready["matched"]?.boolValue == true)

            let transcript = try await client.send("getTranscript")
            #expect(transcript["text"]?.stringValue?.contains("one two three") == true)

            _ = try await client.send("clearMocks", ["scope": "all"])
        }
    }
    }
}
