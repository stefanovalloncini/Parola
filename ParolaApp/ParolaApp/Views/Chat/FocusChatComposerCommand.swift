import SwiftUI

struct FocusChatComposerCommand: View {
    @FocusedValue(\.focusChatComposer) private var focus

    var body: some View {
        Button("Focus Chat Composer") {
            focus?()
        }
        .keyboardShortcut("l", modifiers: [.command])
        .disabled(focus == nil)
    }
}
