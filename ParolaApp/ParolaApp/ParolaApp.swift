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

@main
struct ParolaApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var liveCaptions = LiveCaptionsController()
    @StateObject private var scratchpad = ScratchpadController()
    @State private var shortcutSheetOpen = false
    @State private var micHotkey = MicHotkeyController()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(liveCaptions)
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
                .onOpenURL { url in model.transcribe(fileURL: url) }
                .sheet(isPresented: $shortcutSheetOpen) { ShortcutCheatSheet() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowResizability(.contentSize)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts…") { shortcutSheetOpen = true }
                    .keyboardShortcut("/", modifiers: [.command])
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
                Toggle("Translate to English", isOn: Binding(
                    get: { liveCaptions.translateToEnglish },
                    set: { newValue in
                        Task { await liveCaptions.setTranslate(newValue) }
                    }
                ))
                Divider()
                Button(liveCaptions.isPresenterOpen ? "Exit Presenter" : "Enter Presenter Mode") {
                    liveCaptions.togglePresenter()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
            CommandMenu("Transcript") {
                Button("Copy Plain Text") { model.copyTranscriptToPasteboard(withTimestamps: false) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(model.transcript == nil)
                Button("Copy with Timestamps") { model.copyTranscriptToPasteboard(withTimestamps: true) }
                    .keyboardShortcut("c", modifiers: [.command, .option])
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
                .environmentObject(model)
                .environmentObject(liveCaptions)
                .frame(minWidth: 880, idealWidth: 900, maxWidth: .infinity, minHeight: 600, idealHeight: 640, maxHeight: .infinity)
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
