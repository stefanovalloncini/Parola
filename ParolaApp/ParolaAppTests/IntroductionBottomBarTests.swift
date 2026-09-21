import SwiftUI
import Testing
@testable import Parola

@Suite("Introduction bottom bar")
struct IntroductionBottomBarTests {
    @Test("each step names its primary button and the ax leaf behind it")
    func primaryTitleAndRolePerStep() {
        let expected: [(IntroductionStep, LocalizedStringKey, String)] = [
            (.hello, "Begin", "Begin"),
            (.transcribe, "Continue", "Continue"),
            (.features, "Continue", "Continue"),
            (.engine, "Continue", "Continue"),
            (.ready, "Open Parola", "Finish")
        ]
        for (step, title, role) in expected {
            #expect(IntroductionBottomBar.primaryTitle(step) == title, "\(step)")
            #expect(IntroductionBottomBar.primaryRole(step) == role, "\(step)")
        }
    }

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
