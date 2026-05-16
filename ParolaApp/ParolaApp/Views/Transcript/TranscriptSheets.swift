import SwiftUI

struct SummarySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Summary").font(DS.Font.heading)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(DS.Spacing.regular)
            Divider()
            SummaryPane()
        }
        .frame(minWidth: 520, minHeight: 480)
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
            }
            .padding(DS.Spacing.regular)
            Divider()
            ChatPane()
        }
        .frame(minWidth: 520, minHeight: 480)
    }
}
