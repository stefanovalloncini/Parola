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

    // Four feature cards at order 1 + index is the longest ladder any scene builds.
    @Test("the whole entrance is over inside a third of a second")
    func lastBlockStartsSoon() {
        #expect(SceneEntrance.delay(order: 4) < 0.25)
    }

    @Test("the ramp stops at 210 ms however deep the scene goes")
    func delayIsCapped() {
        #expect(abs(SceneEntrance.delay(order: 4) - 0.21) < 0.0001)
        #expect(abs(SceneEntrance.delay(order: 9) - 0.21) < 0.0001)
    }
}
