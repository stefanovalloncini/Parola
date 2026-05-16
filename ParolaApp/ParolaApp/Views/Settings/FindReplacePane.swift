import SwiftUI
import ParolaCore

struct FindReplacePane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                if model.findReplaceRules.isEmpty {
                    HStack {
                        Text("No rules yet.").foregroundStyle(.secondary).font(.system(size: 13))
                        Spacer()
                    }
                    .padding(16)
                } else {
                    ForEach(Array(model.findReplaceRules.enumerated()), id: \.element.id) { idx, rule in
                        FindReplaceRuleRow(rule: $model.findReplaceRules[idx], isFirst: idx == 0) {
                            model.findReplaceRules.removeAll { $0.id == rule.id }
                        }
                    }
                }
            }

            Button {
                model.findReplaceRules.append(FindReplaceRule(find: "", replace: ""))
            } label: {
                Label("Add rule", systemImage: "plus.circle")
            }

            SettingHelper(text: "Substitutions applied to every new transcript before it's saved.")
        }
    }
}

private struct FindReplaceRuleRow: View {
    @Binding var rule: FindReplaceRule
    let isFirst: Bool
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst { Divider().padding(.leading, 16) }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Toggle("", isOn: $rule.enabled).labelsHidden()
                    TextField("find", text: $rule.find).textFieldStyle(.roundedBorder)
                    Text("→").foregroundStyle(.secondary)
                    TextField("replace with", text: $rule.replace).textFieldStyle(.roundedBorder)
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
                HStack(spacing: 16) {
                    Toggle("Case-sensitive", isOn: $rule.caseSensitive).toggleStyle(.checkbox)
                    Toggle("Regex", isOn: $rule.regex).toggleStyle(.checkbox)
                }
                .font(.system(size: 11))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}
