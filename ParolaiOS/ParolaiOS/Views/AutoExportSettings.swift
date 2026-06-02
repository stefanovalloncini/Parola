import SwiftUI
import ParolaCore

struct AutoExportSettings: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var filter: RuleFilter = .all

    var body: some View {
        @Bindable var model = model
        return Form {
            Section {
                Picker("Filter", selection: $filter) {
                    ForEach(RuleFilter.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
            }

            Section {
                if filteredRuleIDs.isEmpty, !model.autoExportRules.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach($model.autoExportRules) { $rule in
                        if filteredRuleIDs.contains(rule.id) {
                            AutoExportRuleEditor(rule: $rule) {
                                model.autoExportRules.removeAll { $0.id == rule.id }
                            }
                        }
                    }
                }
                Button {
                    model.autoExportRules.append(
                        AutoExportRule(sourceExtensions: ["mp4"], outputFormats: [.srt])
                    )
                } label: {
                    Label("Add rule", systemImage: "plus.circle")
                }
            } header: {
                Text("Rules")
            } footer: {
                Text("Auto-export writes additional files to your library's Exports folder whenever a transcription completes.")
            }
        }
        .searchable(text: $query, prompt: "Search extensions or formats")
    }

    private var filteredRuleIDs: Set<AutoExportRule.ID> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Set(
            model.autoExportRules
                .filter { filter.matches($0.enabled) }
                .filter { rule in
                    guard !trimmed.isEmpty else { return true }
                    if rule.sourceExtensions.contains(where: { $0.lowercased().contains(trimmed) }) {
                        return true
                    }
                    return rule.outputFormats.contains { format in
                        format.fileExtension.lowercased().contains(trimmed)
                            || format.rawValue.lowercased().contains(trimmed)
                    }
                }
                .map(\.id)
        )
    }
}

private struct AutoExportRuleEditor: View {
    @Binding var rule: AutoExportRule
    let onDelete: () -> Void
    @State private var extensionsText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle("Enabled", isOn: $rule.enabled).labelsHidden()
                Text(summary).font(.body.weight(.medium))
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .accessibilityLabel(Text("Delete rule"))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("When source is").font(.caption).foregroundStyle(.secondary)
                TextField("mp4, mov", text: $extensionsText)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: extensionsText) { _, new in
                        rule.sourceExtensions = Set(
                            new.split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                                .filter { !$0.isEmpty }
                        )
                    }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Also write").font(.caption).foregroundStyle(.secondary)
                FlowGrid {
                    ForEach(ExportFormat.allCases, id: \.self) { format in
                        let isOn = rule.outputFormats.contains(format)
                        Button(format.fileExtension) {
                            if isOn { rule.outputFormats.remove(format) }
                            else { rule.outputFormats.insert(format) }
                        }
                        .buttonStyle(.bordered)
                        .tint(isOn ? .accentColor : .secondary)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .onAppear {
            extensionsText = rule.sourceExtensions.sorted().joined(separator: ", ")
        }
    }

    private var summary: String {
        let exts = rule.sourceExtensions.sorted().joined(separator: ", ")
        let fmts = rule.outputFormats.map(\.rawValue).sorted().joined(separator: ", ")
        let left = exts.isEmpty ? "any" : exts
        let right = fmts.isEmpty ? "nothing" : fmts
        return "\(left) → \(right)"
    }
}

private struct FlowGrid<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 50), spacing: 4)],
            alignment: .leading,
            spacing: 4
        ) {
            content()
        }
    }
}

enum RuleFilter: String, CaseIterable, Identifiable {
    case all, enabled, disabled

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .enabled: "Enabled"
        case .disabled: "Disabled"
        }
    }

    func matches(_ enabled: Bool) -> Bool {
        switch self {
        case .all: true
        case .enabled: enabled
        case .disabled: !enabled
        }
    }
}
