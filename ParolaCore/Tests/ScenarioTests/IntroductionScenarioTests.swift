import Foundation
import Testing
import ScenarioKit

extension ScenarioSuite {
    @Suite("Introduction scenarios", .enabled(if: ScenarioSuite.backend == "mock"))
    struct Introduction {
        /// AppleSpeechTranscriber's synthetic model id — the one engine choice every deployment offers.
        private static let appleSpeechID = "apple-speech-analyzer"

        @Test("showIntroduction opens on hello with the full step sequence")
        func opensOnHello() async throws {
            let client = try ScenarioBridgeClient()
            try await client.connect()
            defer { Task { await client.close() } }

            _ = try await client.send("resetTestState")
            let state = try await client.send("showIntroduction")

            #expect(state["visible"]?.boolValue == true)
            #expect(state["step"]?.stringValue == "hello")
            let steps = state["steps"]?.arrayValue?.compactMap(\.stringValue)
            #expect(steps == ["hello", "transcribe", "features", "engine", "ready"])
        }

        @Test("introductionNext walks every step, introductionBack returns one, introductionSkip hides it")
        func walksBackAndSkips() async throws {
            let client = try ScenarioBridgeClient()
            try await client.connect()
            defer { Task { await client.close() } }

            _ = try await client.send("resetTestState")
            let opened = try await client.send("showIntroduction")
            let steps = opened["steps"]?.arrayValue?.compactMap(\.stringValue) ?? []
            #expect(!steps.isEmpty, "precondition: the introduction should offer at least one step")

            for expected in steps.dropFirst() {
                let advanced = try await client.send("introductionNext")
                #expect(advanced["step"]?.stringValue == expected)
            }

            let atTheEnd = try await client.send("introductionNext")
            #expect(atTheEnd["step"]?.stringValue == steps.last, "introductionNext must stop on the last step")

            let back = try await client.send("introductionBack")
            #expect(back["step"]?.stringValue == steps[steps.count - 2])

            let skipped = try await client.send("introductionSkip")
            #expect(skipped["visible"]?.boolValue == false)
        }

        @Test("choosing a non-Apple engine and continuing commits it into selectedModel")
        func choosesEngineAndCommits() async throws {
            let client = try ScenarioBridgeClient()
            try await client.connect()
            defer { Task { await client.close() } }

            _ = try await client.send("resetTestState")
            var state = try await client.send("showIntroduction")
            let engineChoices = state["engineChoices"]?.arrayValue?.compactMap(\.stringValue) ?? []
            guard let choice = engineChoices.first(where: { $0 != Self.appleSpeechID }) else {
                return
            }
            let steps = state["steps"]?.arrayValue?.compactMap(\.stringValue) ?? []

            for _ in steps.indices {
                if state["step"]?.stringValue == "engine" { break }
                state = try await client.send("introductionNext")
            }
            try #require(state["step"]?.stringValue == "engine", "never reached the engine step")

            let chosen = try await client.send("introductionChooseEngine", ["id": choice])
            #expect(chosen["engine"]?.stringValue == choice)

            let advanced = try await client.send("introductionNext")
            #expect(advanced["step"]?.stringValue == "ready")

            let appState = try await client.send("getState")
            #expect(appState["selectedModel"]?.stringValue == choice)
        }

        @Test("introductionSkip persists, and clearing introductionComplete brings it back")
        func finishAndReopenViaSetting() async throws {
            let client = try ScenarioBridgeClient()
            try await client.connect()
            defer { Task { await client.close() } }

            _ = try await client.send("resetTestState")
            _ = try await client.send("showIntroduction")

            // introductionNext stops on the last step without finishing the flow (verified above);
            // introductionSkip is the only bridge command that hides it, the way the last pill does there.
            let skipped = try await client.send("introductionSkip")
            #expect(skipped["visible"]?.boolValue == false)

            _ = try await client.send("setSetting", ["key": "introductionComplete", "value": false])

            let state = try await client.send("getState")
            #expect(state["introduction"]?["visible"]?.boolValue == true)
            #expect(state["introduction"]?["step"]?.stringValue == "hello")
        }
    }
}
