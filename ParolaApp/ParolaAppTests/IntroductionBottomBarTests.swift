import Testing
@testable import Parola

@MainActor
@Suite("Introduction bottom bar")
struct IntroductionBottomBarTests {
    @Test("the last step is the only one that offers a file")
    func openFileOnTheLastStep() {
        #expect(IntroductionBottomBar.secondaryAction(for: .ready) == .openFile)
    }

    @Test("every earlier step leaves the middle of the bar empty")
    func noSecondaryActionEarlier() {
        for step in [IntroductionStep.hello, .transcribe, .features, .engine] {
            #expect(IntroductionBottomBar.secondaryAction(for: step) == nil)
        }
    }
}
