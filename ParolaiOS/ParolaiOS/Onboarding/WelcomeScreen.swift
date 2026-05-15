import SwiftUI

struct WelcomeScreen: View {
    var isActive: Bool = true
    let onContinue: () -> Void

    var body: some View {
        OnboardingScreen(
            headline: "onboarding.welcome.headline",
            body: [
                "onboarding.welcome.body.1",
                "onboarding.welcome.body.2",
                "onboarding.welcome.body.3"
            ],
            primaryTitle: "onboarding.welcome.cta",
            primaryAction: onContinue,
            hero: { AnimatedWaveformView(isActive: isActive) }
        )
    }
}
