import SwiftUI

struct DoneScreen: View {
    var isActive: Bool = true
    let onFinish: () -> Void

    var body: some View {
        OnboardingScreen(
            headline: "onboarding.done.headline",
            body: ["onboarding.done.body"],
            primaryTitle: "onboarding.done.cta",
            primaryAction: onFinish,
            hero: { DoneHero(isActive: isActive) }
        )
    }
}

private struct DoneHero: View {
    let isActive: Bool
    @State private var bounced = false

    var body: some View {
        ZStack {
            if isActive {
                ConfettiBurstView()
            }
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 120, weight: .regular))
                .foregroundStyle(.white, Color.accentColor)
                .symbolEffect(.bounce, value: bounced)
                .shadow(color: Color.accentColor.opacity(0.3), radius: 24, x: 0, y: 8)
        }
        .onChange(of: isActive) { _, active in
            if active { bounced.toggle() }
        }
    }
}
