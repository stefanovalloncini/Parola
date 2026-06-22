import SwiftUI
import ParolaCore

struct PromptOutputSheet: View {
    let output: AppModel.PromptOutput
    @Environment(\.dismiss) private var dismiss
    @State private var copied: Bool = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(output.promptName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: copy) {
                            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .disabled(shownText.isEmpty)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
                .onDisappear {
                    resetTask?.cancel()
                    resetTask = nil
                }
        }
    }

    @ViewBuilder private var content: some View {
        if shownText.isEmpty {
            ContentUnavailableView(
                "No Output",
                systemImage: "sparkles",
                description: Text("The model didn't return any text.")
            )
        } else {
            ScrollView {
                Text(shownText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }

    private var shownText: String { Self.displayText(output.text) }

    static func displayText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func copy() {
        UIPasteboard.general.string = shownText
        copied = true
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}
