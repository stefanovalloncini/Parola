import SwiftUI

@main
struct ParolaiOSApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            AppRoot()
                .environmentObject(model)
        }
    }
}

private struct AppRoot: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("onboardingComplete") private var onboardingComplete: Bool = false
    @State private var deferOnboarding = false

    var body: some View {
        Group {
            if shouldShowOnboarding {
                OnboardingFlow(onFinish: {})
                    .transition(.opacity)
            } else {
                RootView()
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.35), value: shouldShowOnboarding)
        .onOpenURL { url in
            if !onboardingComplete {
                deferOnboarding = true
            }
            Task { await model.handleIncoming(url: url) }
        }
    }

    private var shouldShowOnboarding: Bool {
        !onboardingComplete && !deferOnboarding
    }
}
