import SwiftUI
import AppIntents
import ParolaCore

@main
struct ParolaiOSApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            AppRoot()
                .environmentObject(model)
                .environment(model.playback)
        }
    }
}

struct ParolaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenLastTranscriptIntent(),
            phrases: [
                "Open my last \(.applicationName) transcript",
                "Show last transcript in \(.applicationName)"
            ],
            shortTitle: "Open Last Transcript",
            systemImageName: "doc.text"
        )
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
        .onChange(of: onboardingComplete) { _, completed in
            if !completed { deferOnboarding = false }
        }
    }

    private var shouldShowOnboarding: Bool {
        !onboardingComplete && !deferOnboarding
    }
}
