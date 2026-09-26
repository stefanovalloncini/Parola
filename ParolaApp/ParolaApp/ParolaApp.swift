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
                Button("Show Introduction") { model.restartIntroduction() }
                    .disabled(model.introduction.isPresented || model.downloadBlockedReason != nil)
                Divider()
                Button("Keyboard Shortcuts…") { shortcutSheetOpen = true }
                    .keyboardShortcut("/", modifiers: [.command])
                Button("Copy Model Details") { model.copyModelDetails() }
                    .axLeaf("Menu.Help.CopyModelDetails")
                Button("Send Feedback") {
                    if let url = SupportLinks.feedbackMailto {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Export Diagnostics…") {
                    Task {
                        do {
                            try await model.exportDiagnostics()
                        } catch {
                            model.phase = .failed(
                                message: AppModel.diagnosticsExportFailureMessage(for: error)
                            )
                        }
                    }
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.presentOpenPanel() }
                    .keyboardShortcut("o")
                    .disabled(model.introduction.isPresented)
                Menu("Open Recent") {
                    let recents = model.recentFiles
                    if recents.isEmpty {
                        Text("No Recent Files")
                    } else {
                        ForEach(recents, id: \.self) { url in
                            Button(url.lastPathComponent) { model.transcribe(fileURL: url) }
                        }
                        Divider()
                        Button("Clear Menu") { model.clearRecentFiles() }
                    }
                }
                .disabled(model.introduction.isPresented)
                Button("Save As Parola Document…") { model.saveProjectDocument() }
                    .keyboardShortcut("s")
                    .disabled(!model.hasTranscript)
            }
            CommandGroup(after: .sidebar) {
                @Bindable var model = model
                Button("Show Transcript") { model.setTranscriptPaneMode(.transcript) }
                    .keyboardShortcut("1", modifiers: [.command])
                    .disabled(!model.canShow(.transcript) || model.keyWindowIsViewer)
                Button("Show Summary") { model.setTranscriptPaneMode(.summary) }
                    .keyboardShortcut("2", modifiers: [.command])
                    .disabled(!model.canShow(.summary) || model.keyWindowIsViewer)
                Button("Show Chat") { model.setTranscriptPaneMode(.chat) }
                    .keyboardShortcut("3", modifiers: [.command])
                    .disabled(!model.canShow(.chat) || model.keyWindowIsViewer)
                Toggle("Show Translations Side by Side", isOn: $model.translationSideBySide)
                    .disabled(!model.hasTranslation)
                    .axLeaf("Menu.View.TranslationSideBySide")
                Divider()
                Button("Toggle Inspector") {
                    InspectorVisibility.toggle(in: DefaultsStore.current, isNarrow: model.transcriptPaneIsNarrow)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(!model.mainTranscriptCommandsEnabled)
                Toggle("Always on Top", isOn: $model.mainWindowAlwaysOnTop)
                MiniPlayerCommand()
            }
            CommandGroup(after: .textEditing) {
                Button("Find…") { model.beginFind() }
                    .keyboardShortcut("f", modifiers: [.command])
                    .disabled(!model.findCommandEnabled)
                Button("Find Next") { model.goToNextMatchInKeyWindow() }
                    .keyboardShortcut("g", modifiers: [.command])
                    .disabled(!model.keyWindowFindIsOpen || !model.keyWindowHasMatches)
                Button("Find Previous") { model.goToPreviousMatchInKeyWindow() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(!model.keyWindowFindIsOpen || !model.keyWindowHasMatches)
                Button("Replace All") { model.replaceAllMatches() }
                    .keyboardShortcut("e", modifiers: [.command, .option])
                    .disabled(!model.findIsOpen || !model.hasMatches || model.keyWindowIsViewer)
                Divider()
                Button("Search Library") { model.focusLibrarySearch() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .disabled(model.introduction.isPresented)
                    .axLeaf("Menu.Edit.SearchLibrary")
                Divider()
                Button("Auto-Detect Language") { model.selectedLanguage = nil }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                FocusChatComposerCommand()
            }
            CommandMenu("Playback") {
                Button(model.keyWindowIsPlaying ? "Pause" : "Play") { model.togglePlayPauseInKeyWindow() }
                    .disabled(!model.keyWindowHasPlayer)
                Button("Skip Back 5 Seconds") { model.skipInKeyWindow(by: -5) }
                    .disabled(!model.keyWindowHasPlayer)
                Button("Skip Forward 5 Seconds") { model.skipInKeyWindow(by: 5) }
                    .disabled(!model.keyWindowHasPlayer)
            }
            if model.features.isEnabled(.dictation) || model.features.isEnabled(.liveCaptions) {
                CommandMenu("Captions") {
                    if model.features.isEnabled(.dictation) {
                        Button(scratchpad.isOpen ? "Hide Scratchpad" : "Show Scratchpad") {
                            scratchpad.toggle()
                        }
                        .keyboardShortcut("k", modifiers: [.command, .shift])
                        .disabled(model.introduction.isPresented)
                    }
                    if model.features.isEnabled(.liveCaptions) {
                        Divider()
                        Button(liveCaptions.isActive ? "Stop Live Captions" : "Start Live Captions") {
                            model.toggleLiveCaptions()
                        }
                        .keyboardShortcut("l", modifiers: [.command, .shift])
                        .disabled(
                            !liveCaptions.isActive
                                && (model.introduction.isPresented || model.liveCaptionsUnavailableReason != nil)
                        )
                        Toggle("Translate to English", isOn: translateCaptionsBinding)
                        Divider()
                        Button(liveCaptions.isPresenterOpen ? "Exit Presenter" : "Enter Presenter Mode") {
                            liveCaptions.togglePresenter()
                        }
                        .keyboardShortcut("p", modifiers: [.command, .shift])
                        Button("Save Captions…") { liveCaptions.saveCaptionsHistory() }
                            .disabled(!liveCaptions.hasHistory)
                    }
                }
            }
            CommandMenu("Transcript") {
                Button("Back") { model.returnToOrigin() }
                    .keyboardShortcut("[", modifiers: [.command])
                    .disabled(!model.canReturnToOrigin)
                Divider()
                Button("Copy Plain Text") { model.copyTranscriptToPasteboard(withTimestamps: false, pasteboard: .general) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(!model.mainTranscriptCommandsEnabled)
                Button("Copy with Timestamps") { model.copyTranscriptToPasteboard(withTimestamps: true, pasteboard: .general) }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                    .disabled(!model.mainTranscriptCommandsEnabled)
                Button("Copy as SRT") { model.copyTranscriptAsFormat(.srt) }
                    .disabled(!model.mainTranscriptCommandsEnabled)
                Button("Copy Favorites") { model.copyTranscriptToPasteboard(withTimestamps: true, favoritesOnly: true, pasteboard: .general) }
                    .disabled(model.favoriteSegmentIDs.isEmpty || model.keyWindowIsViewer)
                Button("Send via Mail…") { model.shareTranscriptViaMail() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .disabled(!model.mainTranscriptCommandsEnabled)
                Button("Share…") { model.shareTranscriptAsTextFile() }
                    .disabled(!model.mainTranscriptCommandsEnabled)
                Divider()
                Button("Jump to Next Speaker") { model.jumpToNextSpeaker() }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
                    .disabled(!model.mainTranscriptCommandsEnabled)
                Button("Manage People…") { model.showingPeopleSheet = true }
                Button("Favorite Segment") {
                    guard let id = model.focusedSegmentIDForCommands else { return }
                    model.toggleSegmentFavorite(id)
                }
                .keyboardShortcut("d", modifiers: [.command])
                .disabled(!model.mainTranscriptCommandsEnabled || model.selectedEntryID == nil)
                .help(model.selectedEntryID == nil ? "Save the transcript to the library first" : "")
                Button("Copy as Markdown") { model.copyTranscriptAsFormat(.md) }
                    .disabled(!model.mainTranscriptCommandsEnabled)
                Button("Export Segment Notes…") { model.exportSegmentNotesAsMarkdown() }
                    .disabled(!model.mainTranscriptCommandsEnabled)
                Divider()
                Button("Export…") { model.openExportSheet() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!model.mainTranscriptCommandsEnabled)
                Menu("Export As") {
                    ForEach(Array(model.exportPresets.enumerated()), id: \.element.id) { position, preset in
                        Button {
                            model.exportWithPreset(preset.id)
                        } label: {
                            ExportPresetChecks.label(preset)
                        }
                        // ⌘E has always been the one-key export; it follows whichever preset is on top.
                        .keyboardShortcut(position == 0 ? KeyboardShortcut("e", modifiers: .command) : nil)
                    }
                }
                .disabled(!model.mainTranscriptCommandsEnabled)
                Divider()
                Button("Open in New Window") {
                    guard let id = model.selectedEntryID else { return }
                    model.openEntryWindow(id)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model.selectedEntryID == nil || model.keyWindowIsViewer)
                .help(model.selectedEntryID == nil ? "Save the transcript to the library first" : "")
                if model.destinationsEnabled {
                    Divider()
                    SendToMenu(model: model, entryID: model.selectedEntryID)
                }
                Divider()
                Button("Print Transcript…") { model.printTranscript() }
                    .keyboardShortcut("p", modifiers: [.command])
                    .disabled(!model.mainTranscriptCommandsEnabled)
                Divider()
                Button("Burn Subtitles into Video…") { model.requestBurnSubtitles() }
                    .disabled(!model.mainTranscriptCommandsEnabled)
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

    private var translateCaptionsBinding: Binding<Bool> {
        Binding(
            get: { model.liveCaptionsTranslate },
            set: { model.liveCaptionsTranslate = $0 }
        )
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
