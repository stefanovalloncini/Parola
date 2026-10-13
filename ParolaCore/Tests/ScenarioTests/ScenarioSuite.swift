import Foundation
import Testing
import ScenarioKit

@Suite("Parola scenarios", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["PAROLA_RUN_SCENARIOS"] == "1"))
struct ScenarioSuite {}

extension ScenarioSuite {
    /// Selects the transcription pipeline the scenarios drive: "mock" (deterministic,
    /// the CI default) or "real" (live WhisperKit fed from BlackHole; local smoke only).
    static var backend: String { ProcessInfo.processInfo.environment["PAROLA_SCENARIO_BACKEND"] ?? "mock" }
    static var isReal: Bool { backend == "real" }

    /// The one engine `ModelStore` always has, so a mock run transcribes without downloading first.
    static let installedModelID = "apple-speech-analyzer"
}

extension ScenarioSuite {
    /// Runs `probe` until it returns a value or the deadline passes.
    static func poll<Value>(
        deadline: Duration = .seconds(15),
        every interval: Duration = .milliseconds(100),
        _ probe: () async throws -> Value?
    ) async throws -> Value? {
        let end = ContinuousClock.now + deadline
        while true {
            if let value = try await probe() { return value }
            guard ContinuousClock.now < end else { return nil }
            try await Task.sleep(for: interval)
        }
    }

    static func lastInsertedText(_ client: ScenarioBridgeClient, deadline: Duration = .seconds(15)) async throws -> String? {
        try await poll(deadline: deadline) {
            let text = try await client.send("getLastInsertedText")["lastText"]?.stringValue
            return text?.isEmpty == false ? text : nil
        }
    }
}
