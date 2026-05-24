import SwiftUI

struct MiniPlayerCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Show Mini Player") {
            openWindow(id: "mini-player")
        }
        .keyboardShortcut("m", modifiers: [.command, .option])
        .axLeaf("Menu.Button.ShowMiniPlayer")
    }
}
