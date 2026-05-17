import SwiftUI
import ParolaCore

struct ActionItemsSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        InfoSection(title: titleLabel) {
            if model.isExtractingActionItems {
                progressRow
            } else if model.actionItems.isEmpty {
                emptyRow
            } else {
                ForEach(model.actionItems) { item in
                    ActionItemRow(item: item)
                }
                actionsRow
            }
        }
    }

    private var titleLabel: String {
        if model.actionItems.isEmpty { return "Action Items" }
        return "Action Items · \(model.actionItems.count)"
    }

    private var progressRow: some View {
        HStack(spacing: DS.Spacing.small) {
            ProgressView().controlSize(.small)
            Text("Extracting…")
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.secondaryText)
        }
    }

    private var emptyRow: some View {
        Button("Find action items") { model.extractActionItems() }
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    private var actionsRow: some View {
        HStack(spacing: DS.Spacing.small) {
            Button("Re-extract") { model.extractActionItems() }
                .controlSize(.small)
            Button("Copy") { copyToClipboard() }
                .controlSize(.small)
            Spacer()
            Button("Clear") { model.clearActionItems() }
                .controlSize(.small)
        }
    }

    private func copyToClipboard() {
        let lines = model.actionItems.map { item -> String in
            var parts: [String] = []
            if let assignee = item.assignee { parts.append("[\(assignee)]") }
            parts.append(item.task)
            if let due = item.dueDate { parts.append("[by \(due)]") }
            return "- " + parts.joined(separator: " ")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

private struct ActionItemRow: View {
    let item: ActionItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.tight) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(DS.Color.accent)
                    .font(.system(size: 12))
                if let assignee = item.assignee {
                    Text(assignee)
                        .font(DS.Font.body.weight(.semibold))
                        .foregroundStyle(DS.Color.primaryText)
                }
                Text(item.task)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if let due = item.dueDate {
                Text("by \(due)")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                    .padding(.leading, 18)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
