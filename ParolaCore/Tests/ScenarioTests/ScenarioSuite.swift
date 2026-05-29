import Foundation
import Testing

@Suite("Parola scenarios", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["PAROLA_RUN_SCENARIOS"] == "1"))
struct ScenarioSuite {}

extension ScenarioSuite {
    /// Selects the transcription pipeline the scenarios drive: "mock" (deterministic,
    /// the CI default) or "real" (live WhisperKit fed from BlackHole; local smoke only).
    static var backend: String { ProcessInfo.processInfo.environment["PAROLA_SCENARIO_BACKEND"] ?? "mock" }
    static var isReal: Bool { backend == "real" }
}
