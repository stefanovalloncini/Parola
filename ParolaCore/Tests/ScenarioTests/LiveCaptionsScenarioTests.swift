import Foundation
import Testing
import ScenarioKit

extension ScenarioSuite {
    @Suite("Live captions scenarios", .enabled(if: ScenarioSuite.backend == "mock"))
    struct LiveCaptions {
        @Test("live captions render scripted partials then a confirmed line")
        func rendersCaptions() async throws {
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

            let toggled = try await client.send("toggleLiveCaptions")
            #expect(toggled["liveCaptionsActive"]?.boolValue == true)

            var captionsState = try await client.send("getLiveCaptionsState")
            var attempts = 0
            while (captionsState["confirmedLines"]?.arrayValue ?? []).isEmpty, attempts < 50 {
                try await Task.sleep(for: .milliseconds(100))
                captionsState = try await client.send("getLiveCaptionsState")
                attempts += 1
            }

            let confirmedLines = captionsState["confirmedLines"]?.arrayValue?.compactMap(\.stringValue) ?? []
            #expect(confirmedLines == ["one two three"])
            #expect(captionsState["displayedText"]?.stringValue == "one two three")

            let stopped = try await client.send("toggleLiveCaptions")
            #expect(stopped["liveCaptionsActive"]?.boolValue == false)

            _ = try await client.send("clearMocks", ["scope": "all"])
        }
    }
}
