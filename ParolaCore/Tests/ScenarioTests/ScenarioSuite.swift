import Foundation
import Testing

@Suite("Parola scenarios", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["PAROLA_RUN_SCENARIOS"] == "1"))
struct ScenarioSuite {}
