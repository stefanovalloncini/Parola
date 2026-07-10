import SwiftUI
import ParolaCore

struct AutoExportPane: View {
    @Environment(AppModel.self) private var model
    @State private var searchText = ""
    @State private var enabledFilter: RuleEnabledFilter = .all
    @State private var sort: AutoExportSort = .originalOrder

    var body: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SearchPill(text: $searchText, placeholder: "Search rules…")
                    .frame(maxWidth: 240)
                RuleEnabledFilterChips(filter: $enabledFilter)
                Spacer()
                sortMenu
            }

            SettingsSection {
                if model.autoExportRules.isEmpty {
                    HStack {
                        Text("No rules yet.").foregroundStyle(.secondary).font(.body)
                        Spacer()
                    }
                    .padding(16)
                } else if displayedIndices.isEmpty {
                    HStack {
                        Text("No matches").foregroundStyle(.secondary).font(.body)
                        Spacer()
                    }
                    .padding(16)
                } else {
                    ForEach(Array(displayedIndices.enumerated()), id: \.element) { position, idx in
                        AutoExportRuleRow(
                            rule: $model.autoExportRules[idx],
                            isFirst: position == 0
                        ) {
                            let id = model.autoExportRules[idx].id
                            model.autoExportRules.removeAll { $0.id == id }
                        }
                        // Row state (the extensions draft) must follow the rule, not the slot index.
                        .id(model.autoExportRules[idx].id)
                    }
                }
            }

            Button {
                model.autoExportRules.append(
                    AutoExportRule(sourceExtensions: ["mp4"], outputFormats: [.srt])
                )
                // A live search or the Disabled filter would hide the fresh rule.
                searchText = ""
                enabledFilter = .all
            } label: {
                Label("Add rule", systemImage: "plus.circle")
            }
            .axLeaf("AutoExport.Button.AddRule")

            SettingHelper(text: "Auto-export writes additional files next to the source when transcription completes.")

            SettingsSection("Export options") {
                SettingRow("Subtitle line length",
                           description: "Applied to SRT and VTT exports and to the subtitle QC badges.",
                           isFirst: true) {
                    Picker("", selection: $model.subtitleCaptionLengthRaw) {
                        ForEach(CaptionLength.allCases) { preset in
                            Text(preset.displayName).tag(preset.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 200)
                    .axLeaf("AutoExport.Picker.SubtitleLength")
                }
                SettingRow("Markdown timestamps",
                           description: "Prefix each Markdown paragraph with its start time.") {
                    Toggle("", isOn: $model.markdownTimestamps).labelsHidden()
                        .axLeaf("AutoExport.Toggle.MarkdownTimestamps")
                }
                SettingRow("Plain text timestamps",
                           description: "Prefix each TXT line with its start time.") {
                    Toggle("", isOn: $model.txtExportTimestamps).labelsHidden()
                        .axLeaf("AutoExport.Toggle.TxtTimestamps")
                }
                SettingRow("HTML theme",
                           description: "Color scheme used by the HTML export.") {
                    Picker("", selection: $model.htmlExportThemeRaw) {
                        ForEach(HtmlExportTheme.allCases) { theme in
                            Text(theme.displayName).tag(theme.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 160)
                    .axLeaf("AutoExport.Picker.HtmlTheme")
                }
            }

            ResetPaneButton(scope: .autoExport)
        }
    }

    private var displayedIndices: [Int] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        var indices = model.autoExportRules.indices.filter { idx in
            let rule = model.autoExportRules[idx]
            if !enabledFilter.includes(rule.enabled) { return false }
            if query.isEmpty { return true }
            let sources = rule.sourceExtensions.sorted().joined(separator: ",").lowercased()
            let formats = rule.outputFormats.map(\.rawValue).sorted().joined(separator: ",").lowercased()
            return sources.contains(query) || formats.contains(query)
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
        return indices
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
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(DS.Font.calloutMedium)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort")
        .axLeaf("AutoExport.Menu.Sort")
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
    let isFirst: Bool
    let onDelete: () -> Void
    @State private var extensionsText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst { Divider().padding(.leading, 16) }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("", isOn: $rule.enabled).labelsHidden()
                        .axLeaf("AutoExport.Toggle.RuleEnabled")
                    Text(summary).font(.body.weight(.medium))
                    Spacer()
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .axLeaf("AutoExport.Button.DeleteRule")
                }
                HStack {
                    Text("When source is").font(.caption).foregroundStyle(.secondary)
                    TextField("mp4, mov", text: $extensionsText)
                        .textFieldStyle(.roundedBorder)
                        .axLeaf("AutoExport.TextField.Extensions")
                        .onChange(of: extensionsText) { _, new in
                            rule.sourceExtensions = Set(
                                new.split(separator: ",")
                                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                                    .filter { !$0.isEmpty }
                            )
                        }
                }
                HStack(alignment: .top) {
                    Text("Also write").font(.caption).foregroundStyle(.secondary)
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
        let left = exts.isEmpty ? String(localized: "any") : exts
        let right = fmts.isEmpty ? String(localized: "nothing") : fmts
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
                .tint(isOn ? DS.Color.accent : .secondary)
                .controlSize(.small)
                .axLeaf("AutoExport.Button.Format.\(format.fileExtension)")
            }
        }
    }
}
