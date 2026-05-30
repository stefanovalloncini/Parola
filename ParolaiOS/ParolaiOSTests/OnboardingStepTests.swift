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

    @Test(
        "showsSkip tracks the intermediate steps",
        arguments: [
            (OnboardingStep.welcome, false),
            (.model, true),
            (.language, true),
            (.microphone, true),
            (.done, false),
        ]
    )
    func showsSkip(for step: OnboardingStep, expected: Bool) {
        #expect(step.showsSkip == expected)
    }

    @Test(
        "previous returns the preceding step",
        arguments: [
            (OnboardingStep.model, OnboardingStep.welcome),
            (.language, .model),
            (.microphone, .language),
            (.done, .microphone),
        ]
    )
    func previous(from step: OnboardingStep, expected: OnboardingStep) {
        #expect(step.previous == expected)
    }

    @Test("welcome is the first step")
    func welcomeHasNoPrevious() {
        #expect(OnboardingStep.welcome.previous == nil)
    }

    @Test("initialStep is welcome when no override is set")
    func initialStepFallsBackToWelcome() {
        #expect(ProcessInfo.processInfo.environment["PAROLA_ONBOARDING_STEP"] == nil)
        #expect(OnboardingStep.initialStep == .welcome)
    }
}
