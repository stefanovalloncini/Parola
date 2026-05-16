import SwiftUI
import ParolaCore

struct AutoExportPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection {
                if model.autoExportRules.isEmpty {
                    HStack {
                        Text("No rules yet.").foregroundStyle(.secondary).font(.system(size: 13))
                        Spacer()
                    }
                    .padding(16)
                } else {
                    ForEach(Array(model.autoExportRules.enumerated()), id: \.element.id) { idx, rule in
                        AutoExportRuleRow(rule: $model.autoExportRules[idx], isFirst: idx == 0) {
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

            SettingHelper(text: "Auto-export writes additional files next to the source when transcription completes.")
        }
    }
}

private struct AutoExportRuleRow: View {
    @Binding var rule: AutoExportRule
    let isFirst: Bool
    let onDelete: () -> Void
    @State private var extensionsText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst { Divider().padding(.leading, 16) }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("", isOn: $rule.enabled).labelsHidden()
                    Text(summary).font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
                HStack {
                    Text("When source is").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("mp4, mov", text: $extensionsText)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: extensionsText) { _, new in
                            rule.sourceExtensions = Set(
                                new.split(separator: ",")
                                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                                    .filter { !$0.isEmpty }
                            )
                        }
                }
                HStack(alignment: .top) {
                    Text("Also write").font(.system(size: 11)).foregroundStyle(.secondary)
                    AutoExportFormatChips(selected: $rule.outputFormats)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
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

private struct AutoExportFormatChips: View {
    @Binding var selected: Set<ExportFormat>

    var body: some View {
        let grid = [GridItem(.adaptive(minimum: 50))]
        LazyVGrid(columns: grid, alignment: .leading, spacing: 4) {
            ForEach(ExportFormat.allCases, id: \.self) { format in
                let isOn = selected.contains(format)
                Button(format.fileExtension) {
                    if isOn { selected.remove(format) } else { selected.insert(format) }
                }
                .buttonStyle(.bordered)
                .tint(isOn ? .accentColor : .secondary)
                .controlSize(.small)
            }
        }
    }
}
