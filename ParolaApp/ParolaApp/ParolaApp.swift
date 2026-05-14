import SwiftUI

@main
struct ParolaApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Parola") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Audio…") { model.presentOpenPanel() }
                    .keyboardShortcut("o")
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
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 520, height: 440)
        }
    }
}
