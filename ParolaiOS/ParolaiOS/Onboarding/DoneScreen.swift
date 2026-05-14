import SwiftUI

struct DoneScreen: View {
    let onFinish: () -> Void

    var body: some View {
        OnboardingScreen(
            headline: "onboarding.done.headline",
            body: ["onboarding.done.body"],
            primaryTitle: "onboarding.done.cta",
            primaryAction: onFinish,
            hero: { DoneHero() }
        )
    }
}

private struct DoneHero: View {
    @State private var bounced = false

    var body: some View {
        ZStack {
            ConfettiBurstView()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 120, weight: .regular))
                .foregroundStyle(.white, Color.accentColor)
                .symbolEffect(.bounce, value: bounced)
                .shadow(color: Color.accentColor.opacity(0.3), radius: 24, x: 0, y: 8)
        }
        .onAppear {
            bounced.toggle()
        }
    }
}
