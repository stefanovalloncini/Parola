import Foundation
import Testing
@testable import Parola

@Suite("OnboardingStep")
struct OnboardingStepTests {
    @Test(
        "next returns the following step",
        arguments: [
            (OnboardingStep.welcome, OnboardingStep.model),
            (.model, .language),
            (.language, .microphone),
            (.microphone, .done),
        ]
    )
    func next(from step: OnboardingStep, expected: OnboardingStep) {
        #expect(step.next == expected)
    }

    @Test("done is the last step")
    func doneHasNoNext() {
        #expect(OnboardingStep.done.next == nil)
    }

    @Test(
        "showsBack is true for everything after welcome except done",
        arguments: [
            (OnboardingStep.welcome, false),
            (.model, true),
            (.language, true),
            (.microphone, true),
            (.done, false),
        ]
    )
    func showsBack(for step: OnboardingStep, expected: Bool) {
        #expect(step.showsBack == expected)
    }

    @Test(
        "showsDots only on intermediate steps",
        arguments: [
            (OnboardingStep.welcome, false),
            (.model, true),
            (.language, true),
            (.microphone, true),
            (.done, false),
        ]
    )
    func showsDots(for step: OnboardingStep, expected: Bool) {
        #expect(step.showsDots == expected)
    }
}
