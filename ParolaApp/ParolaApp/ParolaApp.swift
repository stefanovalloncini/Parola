import SwiftUI
import AppKit
import AppIntents
import ParolaCore

@MainActor
private func applyAppAppearance(_ theme: String) {
    let appearance: NSAppearance? = switch theme {
    case "light": NSAppearance(named: .aqua)
    case "dark":  NSAppearance(named: .darkAqua)
    default:      nil
    }
    NSApp.appearance = appearance
}

@MainActor
private func applyAlwaysOnTop(_ on: Bool) {
    for window in NSApp.windows where window.canBecomeMain && !window.title.contains("Mini") {
        window.level = on ? .floating : .normal
    }
}

@MainActor
func handleParolaOpen(_ url: URL, model: AppModel) {
    model.introduction.defer()
    if url.isFileURL {
        model.collectOpenedFile(url)
        return
    }
    guard url.scheme?.lowercased() == "parola" else { return }
    let host = (url.host ?? url.path.split(separator: "/").first.map(String.init) ?? "").lowercased()
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .reduce(into: [String: String]()) { dict, item in
            if let value = item.value { dict[item.name] = value }
        } ?? [:]
    switch host {
    case "transcribe":
        if let path = query["path"] {
            model.transcribe(fileURL: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        }
    case "dictate":
        guard model.features.isEnabled(.dictation) else { return }
        model.startDictationFromIntent()
    case "stop":
        guard model.features.isEnabled(.dictation) else { return }
        model.stopDictationFromIntent()
    case "open":
        if let entryID = query["entry"], model.loadEntry(entryID) {
            if let raw = query["t"], let seconds = Timecode.parse(raw) ?? Double(raw) {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    model.seekTo(seconds: seconds)
                }
            }
        }
    default:
        break
    }
}

@main
struct ParolaApp: App {
    @State private var model: AppModel
    @State private var liveCaptions = LiveCaptionsController()
    @State private var scratchpad = ScratchpadController()
    @State private var shortcutSheetOpen = false
    @State private var aboutSheetOpen = false
    @State private var micHotkey = MicHotkeyController()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let bootstrap = AppBootstrap.test(from: CommandLine.arguments) ?? .normal
        // First, so everything AppModel.init reaches happens inside the sink's lifetime.
        DiagnosticsInstaller.installIfWanted(sideEffects: bootstrap.sideEffects)
        DefaultsStore.current = bootstrap.defaults
        ManagedConfiguration.userSettingsStore = bootstrap.defaults
        // Must precede AppModel: a managed launch resolves its engine choices against ModelStore.shared.
        ModelStore.sharedDirectoryOverride = bootstrap.models
        LibraryStore.sharedLibraryOverride = bootstrap.library
        let m = AppModel(bootstrap: bootstrap)
        let lc = LiveCaptionsController()
        m.liveCaptions = lc
        m.registerIntentPerformers()
        AppDelegate.launchModel = m
        _model = State(initialValue: m)
        _liveCaptions = State(initialValue: lc)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .id(model.themeRevision)
                .demoPlayback()
                .tint(DS.Color.accent)
                .environment(model)
                .environment(liveCaptions)
                .frame(minWidth: MainWindowLayout.minimumWidth, minHeight: MainWindowLayout.minimumHeight)
                .preferredColorScheme(model.preferredColorScheme)
                .bindsEntryWindowOpening(to: model)
                .onAppear {
                    model.liveCaptions = liveCaptions
                    appDelegate.bind(model: model)
                    applyAppAppearance(model.appTheme)
                    micHotkey.bind(model)
                }
                .onChange(of: model.appTheme) { _, newValue in
                    applyAppAppearance(newValue)
                }
                .onChange(of: model.phase) { _, newValue in
                    appDelegate.updateDockBadge(for: newValue)
                }
                .onChange(of: model.mainWindowAlwaysOnTop) { _, on in
                    applyAlwaysOnTop(on)
                }
                .onOpenURL { url in handleParolaOpen(url, model: model) }
                .sheet(isPresented: $shortcutSheetOpen) { ShortcutCheatSheet().environment(model) }
                .sheet(isPresented: $aboutSheetOpen) { AboutSheet().environment(model) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowResizability(.contentSize)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Parola") { aboutSheetOpen = true }
            }
            CommandGroup(replacing: .help) {
                HelpCommands(model: model) { shortcutSheetOpen = true }
            }
            CommandGroup(replacing: .newItem) {
                FileCommands(model: model)
            }
            CommandGroup(after: .sidebar) {
                ViewCommands(model: model)
            }
            CommandGroup(after: .textEditing) {
                EditCommands(model: model)
            }
            CommandMenu("Playback") {
                PlaybackCommands(model: model)
            }
            if model.features.isEnabled(.dictation) || model.features.isEnabled(.liveCaptions) {
                CommandMenu("Captions") {
                    CaptionsCommands(model: model, scratchpad: scratchpad, liveCaptions: liveCaptions)
                }
            }
            CommandMenu("Transcript") {
                TranscriptCommands(model: model)
            }
        }

        Settings {
            SettingsView()
                .tint(DS.Color.accent)
                .environment(model)
                .environment(liveCaptions)
                .frame(minWidth: 880, idealWidth: 900, maxWidth: .infinity, minHeight: 600, idealHeight: 640, maxHeight: .infinity)
                .preferredColorScheme(model.preferredColorScheme)
        }

        // No .id(themeRevision) here: re-identifying the view would release a live window's session.
        WindowGroup("Transcript", id: EntryWindowScene.id, for: LibraryEntry.ID.self) { $entryID in
            EntryWindowView(entryID: entryID)
                .tint(DS.Color.accent)
                .environment(model)
                .preferredColorScheme(model.preferredColorScheme)
        }
        .defaultSize(width: 900, height: 640)

        Window("Mini Player", id: "mini-player") {
            MiniPlayerWindow()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 360, height: 90)
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
            intent: StartDictationIntent(),
            phrases: ["Start \(.applicationName) dictation"],
            shortTitle: "Start Dictation",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: StopDictationIntent(),
            phrases: ["Stop \(.applicationName) dictation"],
            shortTitle: "Stop Dictation",
            systemImageName: "stop.fill"
        )
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: ["Start recording in \(.applicationName)"],
            shortTitle: "Start Recording",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: ["Stop recording in \(.applicationName)"],
            shortTitle: "Stop Recording",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: TranscribeFileIntent(),
            phrases: ["Transcribe a file with \(.applicationName)"],
            shortTitle: "Transcribe File",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: SummarizeLastTranscriptIntent(),
            phrases: ["Summarize my last \(.applicationName) transcript"],
            shortTitle: "Summarize Last Transcript",
            systemImageName: "text.alignleft"
        )
    }
}
