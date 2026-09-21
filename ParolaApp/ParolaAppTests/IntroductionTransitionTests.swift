import Foundation
import Testing
@testable import Parola
import ParolaTestSupport

@Suite("Introduction scene transitions")
struct IntroductionTransitionTests {

    @Test("the hello handoff crossfades, in both directions")
    func handoffCrossfades() {
        #expect(IntroductionView.transitionKind(from: .hello, to: .transcribe) == .fade)
        #expect(IntroductionView.transitionKind(from: .transcribe, to: .hello) == .fade)
    }

    @Test("every other pair of steps slides")
    func everyOtherPairSlides() {
        let fading: Set<Set<IntroductionStep>> = [[.hello, .transcribe]]
        for from in IntroductionStep.allCases {
            for to in IntroductionStep.allCases {
                let expected: IntroductionView.TransitionKind = fading.contains([from, to]) ? .fade : .slide
                #expect(
                    IntroductionView.transitionKind(from: from, to: to) == expected,
                    "\(from) → \(to)"
                )
            }
        }
    }

    @Test("a scene with no move behind it is paired with the step ahead")
    func firstSceneLooksForward() {
        let steps = IntroductionStep.sequence(hasEngineChoice: true)
        #expect(IntroductionView.transitionPartner(previous: nil, step: .hello, steps: steps) == .transcribe)
        #expect(IntroductionView.transitionPartner(previous: nil, step: .features, steps: steps) == .engine)
        #expect(IntroductionView.transitionPartner(previous: nil, step: .ready, steps: steps) == .ready)
        #expect(IntroductionView.transitionPartner(previous: .features, step: .transcribe, steps: steps) == .features)
    }

    @Test("Hello leaves the way it arrived, however the introduction opens")
    func helloAlwaysFades() {
        let steps = IntroductionStep.sequence(hasEngineChoice: false)
        let partner = IntroductionView.transitionPartner(previous: nil, step: .hello, steps: steps)
        #expect(IntroductionView.transitionKind(from: partner, to: .hello) == .fade)
    }

    @MainActor
    @Test("the controller remembers the step each move came from")
    func controllerRemembersThePreviousStep() {
        let controller = IntroductionController(
            defaults: temporaryDefaults(),
            mode: .normal,
            showsInTestMode: false,
            hasEngineChoice: true
        )
        #expect(controller.previousStep == nil)

        controller.advance()
        #expect(controller.step == .transcribe)
        #expect(controller.previousStep == .hello)

        controller.advance()
        #expect(controller.previousStep == .transcribe)

        controller.back()
        #expect(controller.step == .transcribe)
        #expect(controller.previousStep == .features)

        controller.restart()
        #expect(controller.previousStep == nil)
    }

    @MainActor
    @Test("a move that goes nowhere leaves the previous step alone")
    func refusedMovesKeepThePreviousStep() {
        let controller = IntroductionController(
            defaults: temporaryDefaults(),
            mode: .normal,
            showsInTestMode: false,
            hasEngineChoice: true
        )
        controller.back()
        #expect(controller.previousStep == nil)

        controller.advance()
        for _ in controller.steps { controller.advance() }
        #expect(controller.step == .ready)
        #expect(controller.previousStep == .engine)
    }
}
