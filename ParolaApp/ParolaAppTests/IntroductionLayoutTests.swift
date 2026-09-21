import Foundation
import Testing
@testable import Parola

@Suite("Introduction layout")
struct IntroductionLayoutTests {
    @Test("every scene after Hello starts on the same row")
    func topInset() {
        #expect(IntroductionLayout.topInset(stageHeight: 100) == 36)
        #expect(IntroductionLayout.topInset(stageHeight: 600) == 120)
        #expect(IntroductionLayout.topInset(stageHeight: 800) == 160)
    }

    @Test("a short stage never insets past the page padding")
    func shortStageKeepsThePageMargin() {
        #expect(IntroductionLayout.topInset(stageHeight: 0) == DS.Spacing.xlarge)
        #expect(IntroductionLayout.topInset(stageHeight: 179) == DS.Spacing.xlarge)
        #expect(IntroductionLayout.topInset(stageHeight: 180) == DS.Spacing.xlarge)
        #expect(IntroductionLayout.topInset(stageHeight: 185) == 37)
    }

    @Test("Hello's lockup centres a little above the middle")
    func helloCentre() {
        #expect(abs(IntroductionLayout.helloCentre(stageHeight: 800) - 368) < 0.001)
        #expect(abs(IntroductionLayout.helloCentre(stageHeight: 600) - 276) < 0.001)
        #expect(IntroductionLayout.helloCentre(stageHeight: 0) == 0)
    }

    @Test("the lockup offset lifts it by that much")
    func helloOffset() {
        #expect(abs(IntroductionLayout.helloOffset(stageHeight: 800) + 32) < 0.001)
        #expect(abs(IntroductionLayout.helloOffset(stageHeight: 600) + 24) < 0.001)
        #expect(IntroductionLayout.helloOffset(stageHeight: 0) == 0)
    }
}
