import SwiftUI

struct ScratchpadView: View {
    @Bindable var controller: ScratchpadController
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "note.text")
                    .foregroundStyle(DS.Color.accent)
                Text("Focus the text below, then trigger dictation to capture here.")
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Spacing.regular)
            .padding(.top, DS.Spacing.small)

            TextEditor(text: $controller.text)
                .font(DS.Font.body)
                .writingToolsBehavior(.complete)
                .padding(.horizontal, DS.Spacing.small)
                .padding(.vertical, DS.Spacing.snug)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.small)
                        .fill(Color.primary.opacity(0.04))
                )
                .padding(.horizontal, DS.Spacing.regular)
                .focused($editorFocused)
                .onAppear { editorFocused = true }

            HStack {
                Button("Copy") { controller.copyToPasteboard() }
                    .disabled(controller.text.isEmpty)
                    .axLeaf("Scratchpad.Button.Copy")
                Spacer()
                Button(role: .destructive) { controller.clear() } label: {
                    Text("Clear")
                }
                .disabled(controller.text.isEmpty)
                .axLeaf("Scratchpad.Button.Clear")
            }
            .padding(.horizontal, DS.Spacing.regular)
            .padding(.bottom, DS.Spacing.small)
        }
        .frame(minWidth: 320, minHeight: 220)
        .axBranch("Scratchpad")
    }
}
