import Foundation
import Testing
@testable import Parola

@Suite("Introduction stage")
struct IntroductionStageTests {
    @Test("the warm point drifts gently and stays inside the stage")
    func warmPointStaysInside() {
        for second in stride(from: 0.0, through: 180.0, by: 2.5) {
            let point = IntroductionStage.warmPoint(seconds: second)
            #expect(abs(point.x - 0.32) <= 0.08)
            #expect(abs(point.y - 0.28) <= 0.08)
            #expect(point.x > 0 && point.x < 1)
            #expect(point.y > 0 && point.y < 1)
        }
    }

    @Test("each axis comes back around on its own slow period")
    func driftIsSlow() {
        let rest = IntroductionStage.warmPoint(seconds: 0)
        #expect(abs(rest.x - 0.32) < 0.0001)
        #expect(abs(rest.y - 0.28) < 0.0001)
        #expect(abs(IntroductionStage.warmPoint(seconds: 31).x - rest.x) < 0.0001)
        #expect(abs(IntroductionStage.warmPoint(seconds: 27).y - rest.y) < 0.0001)
    }
}
