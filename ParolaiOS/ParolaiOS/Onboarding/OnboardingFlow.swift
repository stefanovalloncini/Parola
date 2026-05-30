import SwiftUI

struct OnboardingFlow: View {
    let onFinish: () -> Void
    @Environment(AppModel.self) private var model
    @State private var step: OnboardingStep = .initialStep
    @State private var finishToken = 0

    var body: some View {
        ZStack(alignment: .top) {
            backgroundWash
                .ignoresSafeArea()

            TabView(selection: $step) {
                WelcomeScreen(
                    isActive: step == .welcome,
                    onContinue: { advance(from: .welcome) }
                )
                .tag(OnboardingStep.welcome)

                ModelPickScreen(
                    onContinue: { advance(from: .model) }
                )
                .tag(OnboardingStep.model)

                LanguagePickScreen(
                    isActive: step == .language,
                    onContinue: { advance(from: .language) }
                )
                .tag(OnboardingStep.language)

                MicrophoneScreen(
                    isActive: step == .microphone,
                    onContinue: { advance(from: .microphone) }
                )
                .tag(OnboardingStep.microphone)

                DoneScreen(isActive: step == .done, onFinish: { finish() })
                    .tag(OnboardingStep.done)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .indexViewStyle(.page(backgroundDisplayMode: .never))

            OnboardingTopBar(step: $step)
                .padding(.top, 8)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: step)
        .sensoryFeedback(.success, trigger: finishToken)
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

    private func finish() {
        finishToken &+= 1
        model.settings.onboardingComplete = true
        onFinish()
    }
}
