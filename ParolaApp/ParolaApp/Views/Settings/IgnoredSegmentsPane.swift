import SwiftUI
import ParolaCore

struct IgnoredSegmentsPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                if model.ignoredSegmentRules.isEmpty {
                    HStack {
                        Text("No patterns yet.").foregroundStyle(.secondary).font(.system(size: 13))
                        Spacer()
                    }
                    .padding(16)
                } else {
                    ForEach(Array(model.ignoredSegmentRules.enumerated()), id: \.element.id) { idx, rule in
                        IgnoredRuleRow(rule: $model.ignoredSegmentRules[idx], isFirst: idx == 0) {
                            model.ignoredSegmentRules.removeAll { $0.id == rule.id }
                        }
                    }
                }
            }

            Button {
                model.ignoredSegmentRules.append(IgnoredSegmentRule(pattern: ""))
            } label: {
                Label("Add pattern", systemImage: "plus.circle")
            }

            SettingHelper(text: "Segments matching a pattern (case-insensitive, trimmed) are removed before saving.")
        }
    }
}

private struct IgnoredRuleRow: View {
    @Binding var rule: IgnoredSegmentRule
    let isFirst: Bool
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst { Divider().padding(.leading, 16) }
            HStack(spacing: 10) {
                Toggle("", isOn: $rule.enabled).labelsHidden()
                TextField("e.g. uh, um, hmm", text: $rule.pattern)
                    .textFieldStyle(.roundedBorder)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}
