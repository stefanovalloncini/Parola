import SwiftUI
import AppIntents
import ParolaCore

@main
struct ParolaApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Parola") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 920, minHeight: 600)
                .onAppear { appDelegate.bind(model: model) }
                .onOpenURL { url in model.transcribe(fileURL: url) }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Audio…") { model.presentOpenPanel() }
                    .keyboardShortcut("o")
                Button("Save As Parola Document…") { model.saveProjectDocument() }
                    .keyboardShortcut("s")
                    .disabled(model.transcript == nil)
            }
            CommandGroup(after: .textEditing) {
                Button("Find…") { model.toggleFind() }
                    .keyboardShortcut("f", modifiers: [.command])
                    .disabled(model.transcript == nil)
            }
            CommandMenu("Captions") {
                Button(model.liveCaptions.isActive ? "Stop Live Captions" : "Start Live Captions") {
                    model.toggleLiveCaptions()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
            CommandMenu("Transcript") {
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
                Button("Burn Subtitles into Video…") { model.burnSubtitlesIntoVideo() }
                    .disabled(model.transcript == nil)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 520, height: 440)
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
