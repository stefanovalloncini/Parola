import SwiftUI
import AppIntents
import ParolaCore

@main
struct ParolaiOSApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model = AppModel()
        model.registerIntentPerformers()
        _model = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            AppRoot()
                .environment(model)
                .environment(model.playback)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.refreshLibraryIfChangedElsewhere() }
                    if phase == .background { Task { await model.coordinator.releaseModelsInBackground() } }
                }
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
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: ["Start recording in \(.applicationName)"],
            shortTitle: "Start Recording",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: SummarizeLastTranscriptIntent(),
            phrases: ["Summarize my last \(.applicationName) transcript"],
            shortTitle: "Summarize Last Transcript",
            systemImageName: "text.alignleft"
        )
    }
}

private struct AppRoot: View {
    @Environment(AppModel.self) private var model
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
        .preferredColorScheme(model.settings.appearance.colorScheme)
        .onOpenURL { url in
            if !model.settings.onboardingComplete {
                deferOnboarding = true
            }
            Task { await model.handleIncoming(url: url) }
        }
        .onChange(of: model.settings.onboardingComplete) { _, completed in
            if !completed { deferOnboarding = false }
        }
    }

    private var shouldShowOnboarding: Bool {
        !model.settings.onboardingComplete && !deferOnboarding
    }
}
