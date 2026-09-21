import Testing
@testable import Parola

@Suite("Scene entrance")
struct SceneEntranceTests {
    @Test("each block follows the one above it by 70 ms")
    func delayPerOrder() {
        #expect(SceneEntrance.delay(order: 0) == 0)
        #expect(abs(SceneEntrance.delay(order: 1) - 0.07) < 0.0001)
        #expect(abs(SceneEntrance.delay(order: 2) - 0.14) < 0.0001)
        #expect(abs(SceneEntrance.delay(order: 3) - 0.21) < 0.0001)
    }

    @Test("the whole entrance is over inside a third of a second")
    func lastBlockStartsSoon() {
        #expect(SceneEntrance.delay(order: 3) < 0.25)
    }
}
