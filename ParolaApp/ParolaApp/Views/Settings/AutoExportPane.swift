import SwiftUI
import ParolaCore

struct AutoExportPane: View {
    @Environment(AppModel.self) private var model
    @State private var searchText = ""
    @State private var enabledFilter: RuleEnabledFilter = .all
    @State private var sort: AutoExportSort = .originalOrder

    var body: some View {
        SettingsForm {
            HStack(spacing: 8) {
                SearchPill(text: $searchText, placeholder: "Search rules…", leaf: "AutoExport.TextField.Search")
                    .frame(maxWidth: 240)
                RuleEnabledFilterChips(filter: $enabledFilter)
                Spacer()
                sortMenu
            }

            SettingsSection {
                if model.autoExportRules.isEmpty {
                    InlineEmptyText("No rules yet")
                } else if displayedRules.isEmpty {
                    HStack {
                        Text("No matches").foregroundStyle(DS.Color.secondaryText).font(DS.Font.body)
                        Spacer()
                    }
                } else {
                    ForEach(Array(displayedRules.enumerated()), id: \.element.id) { position, rule in
                        if let binding = binding(for: rule.id) {
                            AutoExportRuleRow(rule: binding, presets: model.exportPresets) {
                                model.autoExportRules.removeAll { $0.id == rule.id }
                            }
                            // Row state (the extensions draft) must follow the rule, not the slot index.
                            .id(rule.id)
                        }
                    }
                }
            }

            Button {
                model.autoExportRules.append(
                    AutoExportRule(
                        sourceExtensions: ["mp4"],
                        presetIDs: [ExportPreset.builtIn(for: .srt)?.id].compactMap { $0 }
                    )
                )
                // A live search or the Disabled filter would hide the fresh rule.
                searchText = ""
                enabledFilter = .all
            } label: {
                Label("Add Rule", systemImage: "plus.circle")
            }
            .axLeaf("AutoExport.Button.AddRule")

            SettingHelper(text: "When a transcription finishes, each rule writes its presets next to the source file, or into the auto-export folder for recordings and links.")

            SettingsSection {
                SettingRow(
                    "Auto-export folder",
                    descriptionVerbatim: model.autoExportFolder.map { ($0.path as NSString).abbreviatingWithTildeInPath }
                        ?? String(localized: "Not chosen: recordings and links skip auto-export.")
                ) {
                    Button("Choose…") { model.chooseAutoExportFolder() }
                        .axLeaf("AutoExport.Button.ChooseFolder")
                }
            }

            ResetPaneButton(scope: .autoExport)
        }
    }

    private var displayedRules: [AutoExportRule] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        var indices = model.autoExportRules.indices.filter { idx in
            let rule = model.autoExportRules[idx]
            if !enabledFilter.includes(rule.enabled) { return false }
            if query.isEmpty { return true }
            let sources = rule.sourceExtensions.sorted().joined(separator: ",").lowercased()
            let presets = presetNames(for: rule).joined(separator: ",").lowercased()
            return sources.contains(query) || presets.contains(query)
        }
        switch sort {
        case .originalOrder:
            break
        case .sourceAscending:
            indices.sort { sourceKey(at: $0).localizedCaseInsensitiveCompare(sourceKey(at: $1)) == .orderedAscending }
        case .sourceDescending:
            indices.sort { sourceKey(at: $0).localizedCaseInsensitiveCompare(sourceKey(at: $1)) == .orderedDescending }
        case .enabledFirst:
            indices.sort { enabledFirstOrder(lhs: $0, rhs: $1, preferEnabled: true) }
        case .disabledFirst:
            indices.sort { enabledFirstOrder(lhs: $0, rhs: $1, preferEnabled: false) }
        }
        return indices.map { model.autoExportRules[$0] }
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

    private func sourceKey(at index: Int) -> String {
        model.autoExportRules[index].sourceExtensions.sorted().joined(separator: ",")
    }

    private func enabledFirstOrder(lhs: Int, rhs: Int, preferEnabled: Bool) -> Bool {
        let l = model.autoExportRules[lhs].enabled
        let r = model.autoExportRules[rhs].enabled
        if l == r { return lhs < rhs }
        return preferEnabled ? l : r
    }

    private var sortMenu: some View {
        Menu {
            sortOptions
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.button)
        .buttonStyle(DSIconChipButtonStyle(side: 28))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort")
        .accessibilityRepresentation {
            Menu("Sort") { sortOptions }
        }
        .axLeaf("AutoExport.Menu.Sort")
    }

    @ViewBuilder private var sortOptions: some View {
        ForEach(AutoExportSort.allCases, id: \.self) { option in
            Button {
                sort = option
            } label: {
                if sort == option {
                    Label(option.title, systemImage: "checkmark")
                } else {
                    Text(option.title)
                }
            }
        }
    }
}

enum AutoExportSort: CaseIterable {
    case originalOrder
    case sourceAscending
    case sourceDescending
    case enabledFirst
    case disabledFirst

    var title: LocalizedStringKey {
        switch self {
        case .originalOrder: return "Original order"
        case .sourceAscending: return "Source A→Z"
        case .sourceDescending: return "Source Z→A"
        case .enabledFirst: return "Enabled first"
        case .disabledFirst: return "Disabled first"
        }
    }
}

private struct AutoExportRuleRow: View {
    @Binding var rule: AutoExportRule
    let presets: [ExportPreset]
    let onDelete: () -> Void
    @State private var extensionsText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("", isOn: $rule.enabled).labelsHidden()
                        .axLeaf("AutoExport.Toggle.RuleEnabled")
                    Text(summary).font(DS.Font.bodyStrong)
                    Spacer()
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .axLeaf("AutoExport.Button.DeleteRule")
                }
                HStack {
                    Text("When source is").font(DS.Font.secondary).foregroundStyle(DS.Color.secondaryText)
                    TextField("Any file", text: $extensionsText, prompt: Text("Any file"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
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
        }
        .onAppear {
            extensionsText = rule.sourceExtensions.sorted().joined(separator: ", ")
        }
    }

    private var summary: String {
        let exts = rule.sourceExtensions.sorted().joined(separator: ", ")
        let names = rule.presetIDs.compactMap { id in presets.first { $0.id == id }?.name }
        let left = exts.isEmpty ? String(localized: "any") : exts
        let right = names.isEmpty ? String(localized: "nothing") : names.joined(separator: ", ")
        return "\(left) → \(right)"
    }
}
