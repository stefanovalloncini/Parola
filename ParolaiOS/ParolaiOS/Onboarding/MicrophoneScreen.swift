import SwiftUI
import AVFoundation

struct MicrophoneScreen: View {
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var requesting = false
    @State private var responseMessage: LocalizedStringKey?

    var body: some View {
        OnboardingScreen(
            headline: "onboarding.mic.headline",
            body: [
                "onboarding.mic.body",
                "onboarding.mic.privacy"
            ],
            primaryTitle: "onboarding.mic.cta",
            primaryAction: requestPermission,
            secondaryTitle: "onboarding.cta.notnow",
            secondaryAction: { onContinue() },
            hero: { MicRippleView() },
            footer: {
                if let responseMessage {
                    Text(responseMessage)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .transition(.opacity)
                }
            }
        )
        .animation(.smooth, value: responseMessage)
    }

    private func requestPermission() {
        guard !requesting else { return }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            onContinue()
        case .denied, .restricted:
            responseMessage = "onboarding.mic.denied"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { onContinue() }
        case .notDetermined:
            requesting = true
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    requesting = false
                    responseMessage = granted ? nil : "onboarding.mic.denied"
                    DispatchQueue.main.asyncAfter(deadline: .now() + (granted ? 0.2 : 0.9)) {
                        onContinue()
                    }
                }
            }
        @unknown default:
            onContinue()
        }
    }
}
