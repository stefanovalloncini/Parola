import SwiftUI
import ParolaCore
import ParolaDictation

struct CorrectionsPane: View {
    @EnvironmentObject var model: AppModel
    @State private var searchText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SearchPill(text: $searchText, placeholder: "Search corrections…")

            SettingsSection {
                let visible = visibleRules
                if model.correctionRules.isEmpty {
                    HStack {
                        Text("No corrections yet.").foregroundStyle(.secondary).font(.body)
                        Spacer()
                    }
                    .padding(16)
                } else if visible.isEmpty {
                    HStack {
                        Text("No corrections match.").foregroundStyle(.secondary).font(.body)
                        Spacer()
                    }
                    .padding(16)
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
                model.correctionRules.append(CorrectionRule(from: "", to: ""))
            } label: {
                Label("Add correction", systemImage: "plus.circle")
            }

            help
            ResetPaneButton(scope: .corrections)
        }
    }

    private var visibleRules: [CorrectionRule] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return model.correctionRules }
        return model.correctionRules.filter {
            $0.from.lowercased().contains(query) || $0.to.lowercased().contains(query)
        }
    }

    private func binding(for id: CorrectionRule.ID) -> Binding<CorrectionRule>? {
        guard let idx = model.correctionRules.firstIndex(where: { $0.id == id }) else { return nil }
        return $model.correctionRules[idx]
    }

    private var help: some View {
        Text("Word-bounded replacements applied after every dictation. Use this for mis-transcribed jargon like \"q three\" → \"Q3\".")
            .font(.caption)
            .italic()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }
}

private struct CorrectionRow: View {
    @Binding var rule: CorrectionRule
    let isFirst: Bool
    let onDelete: () -> Void

    private var canEnable: Bool {
        !rule.from.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { rule.enabled && canEnable },
            set: { if canEnable { rule.enabled = $0 } }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst { Divider().padding(.leading, 16) }
            HStack(spacing: 8) {
                Toggle("", isOn: enabledBinding)
                    .labelsHidden()
                    .disabled(!canEnable)
                TextField("heard", text: $rule.from)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                Text("→").foregroundStyle(.secondary)
                TextField("write", text: $rule.to)
                    .textFieldStyle(.roundedBorder)
                Toggle("Aa", isOn: $rule.caseSensitive)
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Case-sensitive match")
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
