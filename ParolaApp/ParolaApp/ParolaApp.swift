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
    for window in NSApp.windows where window.title == "Parola" || window.styleMask.contains(.titled) && window.isVisible {
        window.level = on ? .floating : .normal
    }
}

@MainActor
private func handleOpen(_ url: URL, model: AppModel) {
    if url.isFileURL {
        model.transcribe(fileURL: url)
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
        model.startDictationFromIntent()
    case "stop":
        model.stopDictationFromIntent()
    case "open":
        if let entryID = query["entry"] {
            model.loadEntry(entryID)
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
        DefaultsStore.current = bootstrap.defaults
        _model = State(initialValue: AppModel(bootstrap: bootstrap))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .environment(liveCaptions)
                .frame(minWidth: 920, minHeight: 600)
                .preferredColorScheme(model.preferredColorScheme)
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
                .onOpenURL { url in handleOpen(url, model: model) }
                .sheet(isPresented: $shortcutSheetOpen) { ShortcutCheatSheet() }
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
                Button("Keyboard Shortcuts…") { shortcutSheetOpen = true }
                    .keyboardShortcut("/", modifiers: [.command])
                Button("Send Feedback") {
                    if let url = URL(string: "mailto:feedback@parola.app?subject=Parola%20feedback") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Audio…") { model.presentOpenPanel() }
                    .keyboardShortcut("o")
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
                Button("Save As Parola Document…") { model.saveProjectDocument() }
                    .keyboardShortcut("s")
                    .disabled(model.transcript == nil)
            }
            CommandGroup(after: .sidebar) {
                @Bindable var model = model
                Button("Toggle Inspector") {
                    UserDefaults.standard.set(
                        !UserDefaults.standard.bool(forKey: "inspectorVisible"),
                        forKey: "inspectorVisible"
                    )
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(model.transcript == nil)
                Toggle("Always on Top", isOn: $model.mainWindowAlwaysOnTop)
                MiniPlayerCommand()
            }
            CommandGroup(after: .textEditing) {
                Button("Find…") { model.toggleFind() }
                    .keyboardShortcut("f", modifiers: [.command])
                    .disabled(model.transcript == nil)
                Button("Find Next") { model.goToNextMatch() }
                    .keyboardShortcut("g", modifiers: [.command])
                    .disabled(!model.findIsOpen || model.matches.isEmpty)
                Button("Find Previous") { model.goToPreviousMatch() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(!model.findIsOpen || model.matches.isEmpty)
                Button("Replace All") { model.replaceAllMatches() }
                    .keyboardShortcut("e", modifiers: [.command, .option])
                    .disabled(!model.findIsOpen || model.matches.isEmpty)
                Divider()
                Button("Auto-detect Language") { model.selectedLanguage = nil }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                FocusChatComposerCommand()
            }
            CommandMenu("Captions") {
                Button(scratchpad.isOpen ? "Hide Scratchpad" : "Show Scratchpad") {
                    scratchpad.toggle()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                Divider()
                Button(liveCaptions.isActive ? "Stop Live Captions" : "Start Live Captions") {
                    model.toggleLiveCaptions()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                Toggle("Translate to English", isOn: translateCaptionsBinding)
                Divider()
                Button(liveCaptions.isPresenterOpen ? "Exit Presenter" : "Enter Presenter Mode") {
                    liveCaptions.togglePresenter()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Save Captions…") { liveCaptions.saveCaptionsHistory() }
                    .disabled(!liveCaptions.hasHistory)
            }
            CommandMenu("Transcript") {
                Button("Copy Plain Text") { model.copyTranscriptToPasteboard(withTimestamps: false) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(model.transcript == nil)
                Button("Copy with Timestamps") { model.copyTranscriptToPasteboard(withTimestamps: true) }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                    .disabled(model.transcript == nil)
                Button("Copy as SRT") { model.copyTranscriptAsFormat(.srt) }
                    .disabled(model.transcript == nil)
                Button("Send via Mail…") { model.shareTranscriptViaMail() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .disabled(model.transcript == nil)
                Divider()
                Button("Jump to Next Speaker") { model.jumpToNextSpeaker() }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
                    .disabled(model.transcript == nil)
                Button("Copy as Markdown") { model.copyTranscriptAsFormat(.md) }
                    .disabled(model.transcript == nil)
                Button("Export Segment Notes…") { model.exportSegmentNotesAsMarkdown() }
                    .disabled(model.transcript == nil)
                Divider()
                Button("Export as TXT…") { model.exportRequest(.txt) }
                    .keyboardShortcut("e", modifiers: [.command])
                    .disabled(model.transcript == nil)
                Button("Export as Markdown…") { model.exportRequest(.md) }
                    .disabled(model.transcript == nil)
                Button("Export as HTML…") { model.exportRequest(.html) }
                    .disabled(model.transcript == nil)
                Button("Export as Word (.docx)…") { model.exportRequest(.docx) }
                    .disabled(model.transcript == nil)
                Button("Export as PDF…") { model.exportRequest(.pdf) }
                    .disabled(model.transcript == nil)
                Button("Export as CSV…") { model.exportRequest(.csv) }
                    .disabled(model.transcript == nil)
                Button("Export as SRT…") { model.exportRequest(.srt) }
                    .disabled(model.transcript == nil)
                Button("Export as VTT…") { model.exportRequest(.vtt) }
                    .disabled(model.transcript == nil)
                Button("Export as JSON…") { model.exportRequest(.json) }
                    .disabled(model.transcript == nil)
                Divider()
                Button("Open in New Window") {
                    if let t = model.transcript {
                        let title = model.sourceFileURL?.deletingPathExtension().lastPathComponent ?? "Transcript"
                        TranscriptWindowController.shared.open(transcript: t, title: title)
                    }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model.transcript == nil)
                Divider()
                Button("Print Transcript…") { model.printTranscript() }
                    .keyboardShortcut("p", modifiers: [.command])
                    .disabled(model.transcript == nil)
                Divider()
                Button("Burn Subtitles into Video…") { model.burnSubtitlesIntoVideo() }
                    .disabled(model.transcript == nil)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(liveCaptions)
                .frame(minWidth: 880, idealWidth: 900, maxWidth: .infinity, minHeight: 600, idealHeight: 640, maxHeight: .infinity)
        }

        Window("Mini Player", id: "mini-player") {
            MiniPlayerWindow()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 360, height: 90)
    }

    private var translateCaptionsBinding: Binding<Bool> {
        Binding(
            get: { liveCaptions.translateToEnglish },
            set: { newValue in
                Task { await liveCaptions.setTranslate(newValue) }
            }
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
            intent: SummarizeLastTranscriptIntent(),
            phrases: ["Summarize my last \(.applicationName) transcript"],
            shortTitle: "Summarize Last Transcript",
            systemImageName: "text.alignleft"
        )
    }
}
