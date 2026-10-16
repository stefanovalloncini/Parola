import SwiftUI
import ParolaCore

struct AutoExportPane: View {
    @Environment(AppModel.self) private var model
    @State private var query = RuleListQuery()
    @State private var selection: AutoExportRule.ID?

    var body: some View {
        @Bindable var model = model
        let hasFolder = model.autoExportFolder != nil
        let displayed = displayedRules
        return SettingsForm {
            Section {
                if model.autoExportRules.isEmpty {
                    InlineEmptyText("No rules yet")
                } else if displayed.isEmpty {
                    InlineEmptyText("No matches")
                } else {
                    RuleListRows(
                        displayed, selection: $selection, leaf: "AutoExport.Row",
                        label: { $0.summary(presets: model.exportPresets) },
                        removeLabel: "Remove Rule", onRemove: remove
                    ) { rule in
                        if let binding = binding(for: rule.id) {
                            AutoExportRuleRow(rule: binding, presets: model.exportPresets)
                                // Row state (the extensions draft) must follow the rule, not the slot index.
                                .id(rule.id)
                        }
                    }
                }
                RuleListBar(
                    leafPrefix: "AutoExport", addLabel: "Add Rule", removeLabel: "Remove Rule",
                    canRemove: displayed.contains { $0.id == selection },
                    onAdd: add, onRemove: removeSelected
                )
            } header: {
                if query.showsToolbar(ruleCount: model.autoExportRules.count) {
                    RuleListToolbar(query: $query, placeholder: "Search rules…", leafPrefix: "AutoExport")
                }
            }

            SettingHelper(text: "When a transcription finishes, each rule writes its presets next to the source file, or into the Auto-Export folder for recordings and links.")

            SettingsSection {
                SettingRow(
                    "Auto-Export folder",
                    descriptionVerbatim: model.autoExportFolder.map { ($0.path as NSString).abbreviatingWithTildeInPath }
                        ?? String(localized: "Not chosen: recordings and links skip Auto-Export.")
                ) {
                    Button("Choose…") { model.chooseAutoExportFolder() }
                        .axLeaf("AutoExport.Button.ChooseFolder")
                }
                SettingRow(
                    "Also Export the Recording",
                    description: "Copies a recording or meeting's audio to the Auto-Export folder, as it was saved."
                ) {
                    extraToggle($model.autoExportRecording, leaf: "AutoExport.Toggle.Recording", hasFolder: hasFolder)
                }
                if model.features.isEnabled(.ai) {
                    SettingRow(
                        "Also Export the AI Summary",
                        description: "Writes each summary to the Auto-Export folder as a Markdown file, when it is ready."
                    ) {
                        extraToggle($model.autoExportSummary, leaf: "AutoExport.Toggle.Summary", hasFolder: hasFolder)
                    }
                }
            }

            ResetPaneButton(scope: .autoExport)
        }
    }

    @ViewBuilder
    private func extraToggle(_ isOn: Binding<Bool>, leaf: String, hasFolder: Bool) -> some View {
        let toggle = Toggle("", isOn: isOn).labelsHidden()
        if hasFolder {
            toggle.axLeaf(leaf)
        } else {
            toggle.disabled(true).help("Choose an Auto-Export folder first.").axLeaf(leaf)
        }
    }

    private var displayedRules: [AutoExportRule] {
        query.arrange(
            model.autoExportRules,
            fields: { [$0.sourceExtensions.sorted().joined(separator: ","), presetNames(for: $0).joined(separator: ",")] },
            isEnabled: \.enabled
        )
    }

    private func add() {
        query.showNewRule()
        let rule = AutoExportRule(
            sourceExtensions: ["mp4"],
            presetIDs: [ExportPreset.builtIn(for: .srt)?.id].compactMap { $0 }
        )
        model.autoExportRules.append(rule)
        selection = rule.id
    }

    private func removeSelected() {
        guard let selection else { return }
        remove(selection)
    }

    private func remove(_ id: AutoExportRule.ID) {
        model.autoExportRules.removeAll { $0.id == id }
        if selection == id { selection = nil }
    }

    // Resolved by id on every access: an index captured at render time can go stale
    // when a row is deleted before a pending write lands.
    private func binding(for id: AutoExportRule.ID) -> Binding<AutoExportRule>? {
        guard let current = model.autoExportRules.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { model.autoExportRules.first(where: { $0.id == id }) ?? current },
            set: { newValue in
                guard let idx = model.autoExportRules.firstIndex(where: { $0.id == id }) else { return }
                model.autoExportRules[idx] = newValue
            }
        )
    }

    private func presetNames(for rule: AutoExportRule) -> [String] {
        rule.presetIDs.compactMap { id in model.exportPresets.first { $0.id == id }?.name }
    }
}

private struct AutoExportRuleRow: View {
    @Binding var rule: AutoExportRule
    let presets: [ExportPreset]
    @State private var extensionsText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Use this rule", isOn: $rule.enabled).labelsHidden()
                    .axLeaf("AutoExport.Toggle.RuleEnabled")
                Text(rule.summary(presets: presets)).font(DS.Font.bodyStrong)
                Spacer()
            }
            HStack {
                Text("When source is").font(DS.Font.secondary).foregroundStyle(DS.Color.secondaryText)
                TextField("Any file", text: $extensionsText, prompt: Text("Any file"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .selectsRuleRowOnFocus()
                    .axLeaf("AutoExport.TextField.Extensions")
                    .onChange(of: extensionsText) { _, new in
                        rule.sourceExtensions = Set(
                            new.split(separator: ",")
                                .map { AutoExportRule.normalizedExtension(String($0)) }
                                .filter { !$0.isEmpty }
                        )
                    }
            }
            HStack(alignment: .top) {
                Text("Also write").font(DS.Font.secondary).foregroundStyle(DS.Color.secondaryText)
                ExportPresetChecks(
                    presets: presets,
                    leafPrefix: "AutoExport",
                    isOn: { rule.presetIDs.contains($0) },
                    setOn: { id, isOn in
                        if isOn {
                            guard !rule.presetIDs.contains(id) else { return }
                            rule.presetIDs.append(id)
                        } else {
                            rule.presetIDs.removeAll { $0 == id }
                        }
                    }
                )
            }
        }
        .onAppear {
            extensionsText = rule.sourceExtensions.sorted().joined(separator: ", ")
        }
    }
}

private extension AutoExportRule {
    func summary(presets: [ExportPreset]) -> String {
        let exts = sourceExtensions.sorted().joined(separator: ", ")
        let names = presetIDs.compactMap { id in presets.first { $0.id == id }?.name }
        let left = exts.isEmpty ? String(localized: "any") : exts
        let right = names.isEmpty ? String(localized: "nothing") : names.joined(separator: ", ")
        return "\(left) → \(right)"
    }
}
