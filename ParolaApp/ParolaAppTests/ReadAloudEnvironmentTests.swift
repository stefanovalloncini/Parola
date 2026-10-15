import Foundation
import Testing
@testable import Parola

@MainActor
@Suite("Read Aloud environment")
struct ReadAloudEnvironmentTests {
    @Test("the test host gets the silent environment even for a normal launch that asks for the real system")
    func testHostStaysSilent() {
        let bootstrap = AppBootstrap(mode: .normal, sideEffects: BootstrapSideEffect.all, filePicker: TestFilePicker())

        let environment = ReadAloudEnvironment.make(for: bootstrap)

        #expect(environment.mockVoice != nil)
    }

    @Test("a voice change only marks the list stale; the next read re-reads it once")
    func staleInventory() {
        let inventory = StaleVoiceInventory()
        var refreshes = 0

        inventory.refreshIfStale { refreshes += 1 }
        #expect(refreshes == 0)

        inventory.markStale()
        inventory.markStale()
        #expect(refreshes == 0)

        inventory.refreshIfStale { refreshes += 1 }
        inventory.refreshIfStale { refreshes += 1 }
        #expect(refreshes == 1)
    }
}
