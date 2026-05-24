import SwiftUI

struct SummarySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Summary").font(DS.Font.heading)
                Spacer()
                if let text = summaryText {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .axLeaf("SummarySheet.Button.Copy")
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .axLeaf("SummarySheet.Button.Done")
            }
            .padding(DS.Spacing.regular)
            Divider()
            SummaryPane()
        }
        .frame(minWidth: 520, minHeight: 480)
    }

    private var summaryText: String? {
        guard let summary = model.transcript?.summary, !summary.text.isEmpty else { return nil }
        return summary.text
    }
}

struct ChatSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chat").font(DS.Font.heading)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .axLeaf("ChatSheet.Button.Done")
            }
            .padding(DS.Spacing.regular)
            Divider()
            ChatPane()
        }
        .frame(minWidth: 520, minHeight: 480)
    }
}
