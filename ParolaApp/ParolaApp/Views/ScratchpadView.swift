import SwiftUI

struct ScratchpadView: View {
    @ObservedObject var controller: ScratchpadController
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "note.text")
                    .foregroundStyle(DS.Color.accent)
                Text("Focus the text below, then trigger dictation to capture here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            TextEditor(text: $controller.text)
                .font(.system(size: 13))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.04))
                )
                .padding(.horizontal, 12)
                .focused($editorFocused)
                .onAppear { editorFocused = true }

            HStack {
                Button("Copy") { controller.copyToPasteboard() }
                    .disabled(controller.text.isEmpty)
                Spacer()
                Button(role: .destructive) { controller.clear() } label: {
                    Text("Clear")
                }
                .disabled(controller.text.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .frame(minWidth: 320, minHeight: 220)
    }
}
