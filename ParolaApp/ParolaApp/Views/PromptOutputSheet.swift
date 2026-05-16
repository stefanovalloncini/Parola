import SwiftUI
import ParolaCore

struct PromptOutputSheet: View {
    let output: AppModel.PromptOutput
    @Environment(\.dismiss) private var dismiss
    @State private var copied: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(output.promptName).font(DS.Font.heading)
                Spacer()
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(output.text, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(DS.Spacing.regular)
            Divider()
            ScrollView {
                Text(output.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Spacing.regular)
            }
        }
        .frame(minWidth: 520, minHeight: 400)
    }
}
