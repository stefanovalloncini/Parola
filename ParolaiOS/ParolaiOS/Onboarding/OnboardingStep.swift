import Foundation

enum OnboardingStep: Int, CaseIterable, Hashable, Identifiable {
    case welcome
    case model
    case language
    case microphone
    case done

    var id: Int { rawValue }

    var next: OnboardingStep? {
        OnboardingStep(rawValue: rawValue + 1)
    }

    var previous: OnboardingStep? {
        OnboardingStep(rawValue: rawValue - 1)
    }

    var showsDots: Bool { self != .welcome && self != .done }
    var showsBack: Bool { previous != nil && self != .done }
    var showsSkip: Bool { showsDots }

    static var initialStep: OnboardingStep {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["PAROLA_ONBOARDING_STEP"],
           let value = Int(raw),
           let step = OnboardingStep(rawValue: value) {
            return step
        }
        #endif
        return .welcome
    }
}
