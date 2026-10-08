import SwiftUI
import ParolaCore

/// What to do next: the items Find Action Items extracted, else the ones the summary listed.
struct OverviewActionItems: View {
    @Environment(AppModel.self) private var model

    /// Whether an AI run has left anything on this transcript; until one has, Summarize is the only ask.
    static func hasAIResults(_ model: AppModel) -> Bool {
        let summary = model.transcript?.summary
        let summaryText = summary?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !summaryText.isEmpty || !model.smartChapters.isEmpty || !model.actionItems.isEmpty
            || !(summary?.actionItems.isEmpty ?? true)
    }

    static func shows(_ model: AppModel) -> Bool {
        if !model.actionItems.isEmpty || model.isExtractingActionItems || model.actionItemsError != nil { return true }
        if !summaryItems(model).isEmpty { return true }
        return model.features.isEnabled(.ai) && hasAIResults(model)
    }

    static func summaryItems(_ model: AppModel) -> [String] {
        (model.transcript?.summary?.actionItems ?? []).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// "Sam: render the first screen" names who does it; a longer lead-in is part of the task.
    static func split(_ line: String) -> (assignee: String?, task: String) {
        guard let colon = line.firstIndex(of: ":") else { return (nil, line) }
        let lead = line[..<colon].trimmingCharacters(in: .whitespaces)
        let rest = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !lead.isEmpty, !rest.isEmpty, lead.split(separator: " ").count <= 3 else { return (nil, line) }
        return (lead, rest)
    }

    /// The list Copy puts on the pasteboard, one "- " line per item, whichever list shows.
    static func copyText(_ model: AppModel) -> String {
        let lines: [String]
        if model.actionItems.isEmpty {
            lines = summaryItems(model).map { "- " + $0 }
        } else {
            lines = model.actionItems.map { item in
                var parts: [String] = []
                if let assignee = item.assignee { parts.append("[\(assignee)]") }
                parts.append(item.task)
                if let due = item.dueDate { parts.append("[by \(due)]") }
                return "- " + parts.joined(separator: " ")
            }
        }
        return lines.joined(separator: "\n")
    }

    private var summaryItems: [String] { Self.summaryItems(model) }
    private var count: Int { model.actionItems.isEmpty ? summaryItems.count : model.actionItems.count }

    var body: some View {
        OverviewSection(title: count == 0 ? Text("Action Items") : Text("Action Items · \(count)"), menu: menu) {
            if model.isExtractingActionItems {
                OverviewProgressRow(text: "Finding action items…", leaf: "ActionItems.Button.Stop") {
                    model.stopAIRun(.actionItems)
                }
            } else if !model.actionItems.isEmpty {
                ForEach(model.actionItems) { item in
                    ActionItemRow(assignee: item.assignee, task: item.task, due: item.dueDate)
                }
            } else if !summaryItems.isEmpty {
                ForEach(Array(summaryItems.enumerated()), id: \.offset) { _, line in
                    let parts = Self.split(line)
                    ActionItemRow(assignee: parts.assignee, task: parts.task, due: nil)
                }
            } else {
                emptyRows
            }
        } actions: {
            ActionItemActions()
        }
    }

    private var menu: SectionMenu? {
        count == 0 || model.isExtractingActionItems
            ? nil
            : SectionMenu(label: "Action Item Options", leaf: "Inspector.Menu.ActionItems")
    }

    @ViewBuilder
    private var emptyRows: some View {
        if model.features.isEnabled(.ai) {
            Button("Find Action Items") { model.extractActionItems() }
                .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                .disabled(!model.isAIAvailable(for: .prompts))
                .axLeaf("ActionItems.Button.Find")
        }
        if !model.isAIAvailable(for: .prompts), let reason = model.aiUnavailableReason {
            AIStatusNote(message: reason)
        } else if let error = model.actionItemsError {
            AIStatusNote(message: error, kind: .failure)
        }
    }
}

/// The Action Items ⋯ menu: find them again, copy the list, or drop the extracted ones.
struct ActionItemActions: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.features.isEnabled(.ai) {
            Button(model.actionItems.isEmpty ? "Find Action Items" : "Find Again") { model.extractActionItems() }
                .disabled(!model.isAIAvailable(for: .prompts))
                .axLeaf("ActionItems.Button.Reextract")
        }
        Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(OverviewActionItems.copyText(model), forType: .string)
        }
        .axLeaf("ActionItems.Button.Copy")
        if !model.actionItems.isEmpty {
            Button("Clear") { model.clearActionItems() }
                .axLeaf("ActionItems.Button.Clear")
        }
    }
}

private struct ActionItemRow: View {
    let assignee: String?
    let task: String
    let due: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.small) {
            Text(verbatim: "•")
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.secondaryText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(line)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let due {
                    Text("by \(due)")
                        .font(DS.Font.secondary)
                        .foregroundStyle(DS.Color.secondaryText)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var line: AttributedString {
        var text = AttributedString(task)
        if let assignee {
            var name = AttributedString(assignee + ": ")
            name.font = DS.Font.bodyStrong
            text = name + text
        }
        return text
    }
}
