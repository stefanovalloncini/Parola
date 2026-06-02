import Foundation
import Testing
import ScenarioKit

extension ScenarioSuite {
    @Suite("Bridge client smoke")
    struct Smoke {
        @Test("ping reaches a running app")
        func ping() async throws {
            let client = try ScenarioBridgeClient()
            try await client.connect()
            _ = try await client.send("ping")
            await client.close()
        }
    }
}
