import SwiftUI
import ParolaCore

struct PromptOutputSheet: View {
    let output: AppModel.PromptOutput
    @Environment(\.dismiss) private var dismiss
    @State private var copied: Bool = false

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
                    Button {
                        UIPasteboard.general.string = output.text
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
