import SwiftUI

struct SummarySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetFrame(icon: "sparkles", title: "Summary", onClose: { dismiss() }) {
            SummaryPane()
        }
        .sheetSize(width: 560, minHeight: 480, maxHeight: 700)
        .closeLeaf("SummarySheet.Button.Done")
        .headerAccessory {
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
        }
    }

    private var summaryText: String? {
        guard let summary = model.transcript?.summary, !summary.text.isEmpty else { return nil }
        return summary.text
    }
}

struct ChatSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetFrame(icon: "bubble.left.and.text.bubble.right", title: "Chat", onClose: { dismiss() }) {
            ChatPane()
        }
        .sheetSize(width: 560, minHeight: 480, maxHeight: 700)
        .closeLeaf("ChatSheet.Button.Done")
    }
}
