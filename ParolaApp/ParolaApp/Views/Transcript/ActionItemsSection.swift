import SwiftUI
import ParolaCore

struct ActionItemsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        InspectorSection(titleVerbatim: titleLabel) {
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
        if model.actionItems.isEmpty { return String(localized: "Action Items") }
        return String(localized: "Action Items · \(model.actionItems.count)")
    }

    private var progressRow: some View {
        HStack(spacing: DS.Spacing.small) {
            ProgressView().controlSize(.small)
            Text("Finding action items…")
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.secondaryText)
            Spacer()
            Button("Stop") { model.stopAIRun(.actionItems) }
                .controlSize(.small)
                .axLeaf("ActionItems.Button.Stop")
        }
    }

    private var emptyRow: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            Button("Find Action Items") { model.extractActionItems() }
                .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                .disabled(!model.isAIAvailable(for: .prompts))
                .accessibilityIdentifier("transcript.inspector.actionItems")
                .axLeaf("ActionItems.Button.Find")
            statusNote
        }
    }

    @ViewBuilder
    private var statusNote: some View {
        if !model.isAIAvailable(for: .prompts), let reason = model.aiUnavailableReason {
            AIStatusNote(message: reason)
        } else if let error = model.actionItemsError {
            AIStatusNote(message: error, kind: .failure)
        }
    }

    private var actionsRow: some View {
        HStack(spacing: DS.Spacing.small) {
            Button("Find Again") { model.extractActionItems() }
                .controlSize(.small)
                .disabled(!model.isAIAvailable(for: .prompts))
                .axLeaf("ActionItems.Button.Reextract")
            Button("Copy") { copyToClipboard() }
                .controlSize(.small)
                .axLeaf("ActionItems.Button.Copy")
            Spacer()
            Button("Clear") { model.clearActionItems() }
                .controlSize(.small)
                .axLeaf("ActionItems.Button.Clear")
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
                    .font(DS.Font.secondary)
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
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                    .padding(.leading, DS.Spacing.medium)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
