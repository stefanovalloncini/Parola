import SwiftUI
import ParolaCore
import ParolaDictation

struct CorrectionsPane: View {
    @Environment(AppModel.self) private var model
    @State private var query = RuleListQuery()
    @State private var selection: CorrectionRule.ID?

    var body: some View {
        let visible = visibleRules
        return SettingsForm {
            Section {
                if model.correctionRules.isEmpty {
                    InlineEmptyText("No corrections yet")
                } else if visible.isEmpty {
                    InlineEmptyText("No corrections match.")
                } else {
                    RuleListRows(visible, selection: $selection, leaf: "Corrections.Row", removeLabel: "Remove Correction", onRemove: remove) { rule in
                        if let binding = binding(for: rule.id) {
                            CorrectionRow(rule: binding)
                        }
                    }
                }
                RuleListBar(
                    leafPrefix: "Corrections", addLabel: "Add Correction", removeLabel: "Remove Correction",
                    canRemove: visible.contains { $0.id == selection },
                    onAdd: add, onRemove: removeSelected
                )
            } header: {
                if query.showsToolbar(ruleCount: model.correctionRules.count) {
                    RuleListToolbar(query: $query, placeholder: "Search corrections…", leafPrefix: "Corrections")
                }
            }

            SettingHelper(text: "Word-bounded replacements applied after every dictation. Use this for mis-transcribed jargon like “q three” → “Q3”.")
            ResetPaneButton(scope: .corrections)
        }
    }

    private func add() {
        query.showNewRule()
        let rule = CorrectionRule(from: "", to: "")
        model.correctionRules.append(rule)
        selection = rule.id
    }

    private func removeSelected() {
        guard let selection else { return }
        remove(selection)
    }

    private func remove(_ id: CorrectionRule.ID) {
        model.correctionRules.removeAll { $0.id == id }
        if selection == id { selection = nil }
    }

    private var visibleRules: [CorrectionRule] {
        query.arrange(model.correctionRules, fields: { [$0.from, $0.to] }, isEnabled: CorrectionRow.isEffectivelyEnabled)
    }

    // Resolved by id on every access: an index captured at render time can go stale
    // when a row is deleted before a pending write lands.
    private func binding(for id: CorrectionRule.ID) -> Binding<CorrectionRule>? {
        guard let current = model.correctionRules.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { model.correctionRules.first(where: { $0.id == id }) ?? current },
            set: { newValue in
                guard let idx = model.correctionRules.firstIndex(where: { $0.id == id }) else { return }
                model.correctionRules[idx] = newValue
            }
        )
    }
}

private struct CorrectionRow: View {
    @Binding var rule: CorrectionRule

    private var canEnable: Bool {
        !rule.from.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isEffectivelyEnabled(_ rule: CorrectionRule) -> Bool {
        rule.enabled && !rule.from.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { Self.isEffectivelyEnabled(rule) },
            set: { if canEnable { rule.enabled = $0 } }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            Toggle("Use this rule", isOn: enabledBinding)
                .labelsHidden()
                .disabled(!canEnable)
                .axLeaf("Corrections.Toggle.RuleEnabled")
            TextField("heard", text: $rule.from, prompt: Text("heard"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)
                .selectsRuleRowOnFocus()
                .axLeaf("Corrections.TextField.From")
            Text("→").foregroundStyle(DS.Color.secondaryText)
            TextField("write", text: $rule.to, prompt: Text("write"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .selectsRuleRowOnFocus()
                .axLeaf("Corrections.TextField.To")
            Toggle("Case-sensitive", isOn: $rule.caseSensitive)
                .toggleStyle(.checkbox)
                .font(DS.Font.secondary)
                .fixedSize()
                .axLeaf("Corrections.Toggle.CaseSensitive")
        }
    }
}
