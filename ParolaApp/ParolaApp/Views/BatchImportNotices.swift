import SwiftUI

/// What an import is doing before its files join the list: still checking them, or skipping ones the library holds.
struct BatchImportNotices: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let checking = model.batchCheckingNotice {
                checkingNotice(checking)
                Divider()
            }
            if let notice = model.batchDuplicateNotice {
                duplicateNotice(notice)
                Divider()
            }
        }
    }

    private func checkingNotice(_ text: String) -> some View {
        HStack(spacing: DS.Spacing.small) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.secondaryText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.subtleFill)
        .axLeaf("Batch.Text.CheckingFiles")
    }

    private func duplicateNotice(_ text: String) -> some View {
        HStack(spacing: DS.Spacing.small) {
            Image(systemName: "doc.on.doc")
                .foregroundStyle(DS.Color.secondaryText)
            Text(text)
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Color.secondaryText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.subtleFill)
        .axLeaf("Batch.Text.DuplicatesSkipped")
    }
}
