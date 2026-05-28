import Testing
import ScenarioKit

@Suite("Bridge client smoke", .serialized)
struct BridgeClientSmokeTests {
    @Test("ping reaches a running app")
    func ping() async throws {
        let client = try ScenarioBridgeClient()
        try await client.connect()
        _ = try await client.send("ping")
        await client.close()
    }
}
