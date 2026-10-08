import SwiftUI
import ParolaCore

struct IgnoredSegmentsPane: View {
    @Environment(AppModel.self) private var model
    @State private var query = RuleListQuery()
    @State private var selection: IgnoredSegmentRule.ID?

    var body: some View {
        let displayed = displayedRules
        return SettingsForm {
            Section {
                if model.ignoredSegmentRules.isEmpty {
                    InlineEmptyText("No patterns yet")
                } else if displayed.isEmpty {
                    InlineEmptyText("No matches")
                } else {
                    ForEach(displayed) { rule in
                        if let binding = binding(for: rule.id) {
                            IgnoredRuleRow(rule: binding)
                                .ruleListRow(rule.id, selection: $selection, leaf: "IgnoredSegments.Row")
                        }
                    }
                }
                RuleListBar(
                    leafPrefix: "IgnoredSegments", addLabel: "Add Pattern", removeLabel: "Remove Pattern",
                    canRemove: displayed.contains { $0.id == selection },
                    onAdd: add, onRemove: removeSelected
                )
            } header: {
                if query.showsToolbar(ruleCount: model.ignoredSegmentRules.count) {
                    RuleListToolbar(query: $query, placeholder: "Search patterns…", leafPrefix: "IgnoredSegments")
                }
            }

            SettingHelper(text: "A segment is removed when its entire text equals a pattern (case-insensitive, trimmed). Catches filler-only segments like “uh” — not words inside sentences. Applies to new transcriptions; saved transcripts don't change.")
            ResetPaneButton(scope: .ignoredSegments)
        }
    }

    private func add() {
        query.showNewRule()
        let rule = IgnoredSegmentRule(pattern: "")
        model.ignoredSegmentRules.append(rule)
        selection = rule.id
    }

    private func removeSelected() {
        guard let selection else { return }
        model.ignoredSegmentRules.removeAll { $0.id == selection }
        self.selection = nil
    }

    private var displayedRules: [IgnoredSegmentRule] {
        query.arrange(model.ignoredSegmentRules, fields: { [$0.pattern] }, isEnabled: IgnoredRuleRow.isEffectivelyEnabled)
    }

    // Resolved by id on every access: an index captured at render time can go stale
    // when a row is deleted before a pending write lands.
    private func binding(for id: IgnoredSegmentRule.ID) -> Binding<IgnoredSegmentRule>? {
        guard let current = model.ignoredSegmentRules.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { model.ignoredSegmentRules.first(where: { $0.id == id }) ?? current },
            set: { newValue in
                guard let idx = model.ignoredSegmentRules.firstIndex(where: { $0.id == id }) else { return }
                model.ignoredSegmentRules[idx] = newValue
            }
        )
    }
}

private struct IgnoredRuleRow: View {
    @Binding var rule: IgnoredSegmentRule

    private var canEnable: Bool {
        !rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isEffectivelyEnabled(_ rule: IgnoredSegmentRule) -> Bool {
        rule.enabled && !rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { Self.isEffectivelyEnabled(rule) },
            set: { if canEnable { rule.enabled = $0 } }
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            Toggle("Use this rule", isOn: enabledBinding)
                .labelsHidden()
                .disabled(!canEnable)
                .axLeaf("IgnoredSegments.Toggle.RuleEnabled")
            TextField("e.g. uh", text: $rule.pattern, prompt: Text("e.g. uh"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .selectsRuleRowOnFocus()
                .axLeaf("IgnoredSegments.TextField.Pattern")
        }
    }
}
