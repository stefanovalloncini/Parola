import SwiftUI

@main
struct ParolaApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Parola") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 720, minHeight: 480)
                .onAppear { appDelegate.bind(model: model) }
                .onOpenURL { url in model.transcribe(fileURL: url) }
        }
        .windowResizability(.contentSize)
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
            CommandMenu("Transcript") {
                Button("Export as TXT…") { model.exportRequest(.txt) }
                    .keyboardShortcut("e", modifiers: [.command])
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
