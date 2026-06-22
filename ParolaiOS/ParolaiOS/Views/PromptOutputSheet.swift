import SwiftUI
import ParolaCore

struct PromptOutputSheet: View {
    let output: AppModel.PromptOutput
    @Environment(\.dismiss) private var dismiss
    @State private var copied: Bool = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(output.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(output.promptName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: copy) {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
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

    private func copy() {
        UIPasteboard.general.string = output.text
        copied = true
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}
