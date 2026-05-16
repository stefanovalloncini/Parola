import SwiftUI
import ParolaCore

struct PromptOutputSheet: View {
    let output: AppModel.PromptOutput
    @Environment(\.dismiss) private var dismiss
    @State private var copied: Bool = false

    var body: some View {
        SheetFrame(
            icon: iconName,
            iconTint: DS.Color.accent,
            title: output.promptName,
            onClose: { dismiss() },
            content: { contentBody },
            footer: { footerBody }
        )
    }

    private var contentBody: some View {
        ScrollView {
            Text(output.text)
                .font(DS.Font.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Spacing.regular)
        }
    }

    private var footerBody: some View {
        HStack(spacing: DS.Spacing.small) {
            Button("Close") { dismiss() }
                .sheetSecondaryAction()
                .keyboardShortcut(.cancelAction)

            Spacer()

            Button(action: copy) {
                Label(copied ? "Copied" : "Copy",
                      systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .sheetPrimaryAction()
            .keyboardShortcut(.defaultAction)
        }
    }

    private var iconName: String {
        let lower = output.promptName.lowercased()
        if lower.contains("chapter") { return "list.bullet.rectangle" }
        if lower.contains("summary") || lower.contains("summar") { return "text.alignleft" }
        if lower.contains("translate") || lower.contains("translat") { return "character.bubble" }
        if lower.contains("action") || lower.contains("todo") { return "checklist" }
        return "sparkles"
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(output.text, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
