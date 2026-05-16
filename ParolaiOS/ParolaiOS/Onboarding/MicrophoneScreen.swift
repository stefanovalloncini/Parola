import SwiftUI
import AVFoundation

struct MicrophoneScreen: View {
    var isActive: Bool = true
    let onContinue: () -> Void

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
            primaryAction: { Task { await requestPermission() } },
            secondaryTitle: "onboarding.cta.notnow",
            secondaryAction: { onContinue() },
            hero: { MicRippleView(isActive: isActive) },
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

    private func requestPermission() async {
        guard !requesting else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            onContinue()
        case .denied, .restricted:
            responseMessage = "onboarding.mic.denied"
            try? await Task.sleep(for: .milliseconds(900))
            onContinue()
        case .notDetermined:
            requesting = true
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            requesting = false
            responseMessage = granted ? nil : "onboarding.mic.denied"
            try? await Task.sleep(for: .milliseconds(granted ? 200 : 900))
            onContinue()
        @unknown default:
            onContinue()
        }
    }
}
