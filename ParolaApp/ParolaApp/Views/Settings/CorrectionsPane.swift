import SwiftUI
import ParolaCore
import ParolaDictation

struct CorrectionsPane: View {
    @Environment(AppModel.self) private var model
    @State private var query = RuleListQuery()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if query.showsToolbar(ruleCount: model.correctionRules.count) {
                RuleListToolbar(query: $query, placeholder: "Search corrections…", leafPrefix: "Corrections")
            }

            SettingsSection {
                let visible = visibleRules
                if model.correctionRules.isEmpty {
                    InlineEmptyText("No corrections yet")
                } else if visible.isEmpty {
                    HStack {
                        Text("No corrections match.").foregroundStyle(DS.Color.secondaryText).font(DS.Font.body)
                        Spacer()
                    }
                    .padding(DS.Spacing.medium)
                } else {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { idx, rule in
                        if let binding = binding(for: rule.id) {
                            CorrectionRow(rule: binding, isFirst: idx == 0) {
                                model.correctionRules.removeAll { $0.id == rule.id }
                            }
                        }
                    }
                }
            }

            Button {
                query.showNewRule()
                model.correctionRules.append(CorrectionRule(from: "", to: ""))
            } label: {
                Label("Add Correction", systemImage: "plus.circle")
            }
            .axLeaf("Corrections.Button.AddCorrection")

            SettingHelper(text: "Word-bounded replacements applied after every dictation. Use this for mis-transcribed jargon like “q three” → “Q3”.")
            ResetPaneButton(scope: .corrections)
        }
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
    let isFirst: Bool
    let onDelete: () -> Void

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
        VStack(spacing: 0) {
            if !isFirst { Divider().padding(.leading, DS.Spacing.medium) }
            HStack(spacing: 8) {
                Toggle("Use this rule", isOn: enabledBinding)
                    .labelsHidden()
                    .disabled(!canEnable)
                    .axLeaf("Corrections.Toggle.RuleEnabled")
                TextField("heard", text: $rule.from)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                    .axLeaf("Corrections.TextField.From")
                Text("→").foregroundStyle(DS.Color.secondaryText)
                TextField("write", text: $rule.to)
                    .textFieldStyle(.roundedBorder)
                    .axLeaf("Corrections.TextField.To")
                Toggle("Case-sensitive", isOn: $rule.caseSensitive)
                    .toggleStyle(.checkbox)
                    .font(DS.Font.secondary)
                    .fixedSize()
                    .axLeaf("Corrections.Toggle.CaseSensitive")
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .axLeaf("Corrections.Button.Delete")
            }
            .padding(.horizontal, DS.Spacing.medium)
            .padding(.vertical, DS.Spacing.small)
        }
    }
}
