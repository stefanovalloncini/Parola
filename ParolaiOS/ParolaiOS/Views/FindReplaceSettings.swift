import SwiftUI
import ParolaCore

struct FindReplaceSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach($model.findReplaceRules) { $rule in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle("Enabled", isOn: $rule.enabled).labelsHidden()
                            TextField("find", text: $rule.find)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            Text("→").foregroundStyle(.secondary)
                            TextField("replace", text: $rule.replace)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            Button(role: .destructive) {
                                model.findReplaceRules.removeAll { $0.id == rule.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                        HStack(spacing: 16) {
                            Toggle("Case-sensitive", isOn: $rule.caseSensitive)
                            Toggle("Regex", isOn: $rule.regex)
                        }
                        .font(.caption)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 6)
                }
                Button {
                    model.findReplaceRules.append(FindReplaceRule(find: "", replace: ""))
                } label: {
                    Label("Add rule", systemImage: "plus.circle")
                }
            } header: {
                Text("Substitutions")
            } footer: {
                Text("Applied to every new transcript before it's saved.")
            }
        }
    }
}
