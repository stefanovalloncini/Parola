import SwiftUI
import ParolaCore

struct PromptOutputSheet: View {
    let output: AppModel.PromptOutput
    @Environment(\.dismiss) private var dismiss
    @State private var copied: Bool = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        SheetFrame(
            titleVerbatim: output.promptName,
            onClose: { dismiss() },
            content: { contentBody },
            footer: { footerBody }
        )
        .footerHasCancel(output.failure == nil)
        .onDisappear {
            resetTask?.cancel()
            resetTask = nil
        }
    }

    @ViewBuilder private var contentBody: some View {
        if let failure = output.failure {
            ContentUnavailableView {
                Label("Couldn't Run This Prompt", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: failure)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if shownText.isEmpty {
            ContentUnavailableView(
                "No Output",
                systemImage: "sparkles",
                description: Text("The model didn't return any text.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                Text(shownText)
                    .font(DS.Font.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Spacing.regular)
            }
        }
    }

    private var shownText: String { Self.displayText(output.text) }

    static func displayText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder private var footerBody: some View {
        if output.failure != nil {
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .sheetPrimaryAction()
                    .keyboardShortcut(.defaultAction)
                    .axLeaf("PromptOutput.Button.Close")
            }
        } else {
            HStack(spacing: DS.Spacing.small) {
                Spacer()

                Button("Close") { dismiss() }
                    .sheetSecondaryAction()
                    .keyboardShortcut(.cancelAction)
                    .axLeaf("PromptOutput.Button.Close")

                Button(action: copy) {
                    Label(copied ? "Copied" : "Copy",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .sheetPrimaryAction()
                .keyboardShortcut(.defaultAction)
                .disabled(shownText.isEmpty)
                .axLeaf("PromptOutput.Button.Copy")
            }
        }
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(shownText, forType: .string)
        copied = true
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}
