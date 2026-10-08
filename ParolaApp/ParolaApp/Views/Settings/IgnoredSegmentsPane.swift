import SwiftUI
import ParolaCore

struct IgnoredSegmentsPane: View {
    @Environment(AppModel.self) private var model
    @State private var query = RuleListQuery()

    var body: some View {
        @Bindable var model = model
        return SettingsForm {
            if query.showsToolbar(ruleCount: model.ignoredSegmentRules.count) {
                RuleListToolbar(query: $query, placeholder: "Search patterns…", leafPrefix: "IgnoredSegments")
            }

            SettingsSection {
                if model.ignoredSegmentRules.isEmpty {
                    InlineEmptyText("No patterns yet")
                } else if displayedRules.isEmpty {
                    HStack {
                        Text("No matches").foregroundStyle(DS.Color.secondaryText).font(DS.Font.body)
                        Spacer()
                    }
                } else {
                    ForEach(Array(displayedRules.enumerated()), id: \.element.id) { position, rule in
                        if let binding = binding(for: rule.id) {
                            IgnoredRuleRow(rule: binding, isFirst: position == 0) {
                                model.ignoredSegmentRules.removeAll { $0.id == rule.id }
                            }
                        }
                    }
                }
            }

            Button {
                query.showNewRule()
                model.ignoredSegmentRules.append(IgnoredSegmentRule(pattern: ""))
            } label: {
                Label("Add Pattern", systemImage: "plus.circle")
            }
            .axLeaf("IgnoredSegments.Button.AddPattern")

            SettingHelper(text: "A segment is removed when its entire text equals a pattern (case-insensitive, trimmed). Catches filler-only segments like “uh” — not words inside sentences. Applies to new transcriptions; saved transcripts don't change.")
            ResetPaneButton(scope: .ignoredSegments)
        }
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
    let isFirst: Bool
    let onDelete: () -> Void

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
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Toggle("Use this rule", isOn: enabledBinding)
                    .labelsHidden()
                    .disabled(!canEnable)
                    .axLeaf("IgnoredSegments.Toggle.RuleEnabled")
                TextField("e.g. uh", text: $rule.pattern, prompt: Text("e.g. uh"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .axLeaf("IgnoredSegments.TextField.Pattern")
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .axLeaf("IgnoredSegments.Button.Delete")
            }
        }
    }
}
