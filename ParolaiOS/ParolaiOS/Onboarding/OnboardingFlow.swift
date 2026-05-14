import SwiftUI
import UIKit

struct OnboardingFlow: View {
    let onFinish: () -> Void
    @EnvironmentObject private var model: AppModel
    @State private var step: OnboardingStep = .initialStep

    var body: some View {
        ZStack(alignment: .top) {
            backgroundWash
                .ignoresSafeArea()

            TabView(selection: $step) {
                WelcomeScreen(onContinue: { advance(from: .welcome) })
                    .tag(OnboardingStep.welcome)

                ModelPickScreen(
                    onContinue: { advance(from: .model) },
                    onSkip: { skip() }
                )
                .tag(OnboardingStep.model)

                LanguagePickScreen(
                    onContinue: { advance(from: .language) },
                    onSkip: { skip() }
                )
                .tag(OnboardingStep.language)

                MicrophoneScreen(
                    onContinue: { advance(from: .microphone) },
                    onSkip: { skip() }
                )
                .tag(OnboardingStep.microphone)

                DoneScreen(onFinish: { finish() })
                    .tag(OnboardingStep.done)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .indexViewStyle(.page(backgroundDisplayMode: .never))

            OnboardingTopBar(step: $step)
                .padding(.top, 8)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: step)
    }

    private var backgroundWash: some View {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.12), Color(.systemBackground)],
            startPoint: .top,
            endPoint: .center
        )
        .background(Color(.systemBackground))
    }

    private func advance(from current: OnboardingStep) {
        if let next = current.next {
            step = next
        } else {
            finish()
        }
    }

    private func skip() {
        step = .done
    }

    private func finish() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        model.settings.onboardingComplete = true
        onFinish()
    }
}
