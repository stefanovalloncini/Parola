import SwiftUI
import ParolaCore

struct FindReplacePane: View {
    @Environment(AppModel.self) private var model
    @State private var searchText: String = ""
    @State private var statusFilter: StatusFilter = .all
    @State private var sortOption: SortOption = .original

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SearchPill(text: $searchText, placeholder: "Search rules…")
            filterRow

            SettingsSection {
                let visible = visibleRules
                if model.findReplaceRules.isEmpty {
                    HStack {
                        Text("No rules yet.").foregroundStyle(.secondary).font(.body)
                        Spacer()
                    }
                    .padding(16)
                } else if visible.isEmpty {
                    HStack {
                        Text("No rules match.").foregroundStyle(.secondary).font(.body)
                        Spacer()
                    }
                    .padding(16)
                } else {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { idx, rule in
                        if let binding = binding(for: rule.id) {
                            FindReplaceRuleRow(rule: binding, isFirst: idx == 0) {
                                model.findReplaceRules.removeAll { $0.id == rule.id }
                            }
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    model.findReplaceRules.append(FindReplaceRule(find: "", replace: ""))
                } label: {
                    Label("Add rule", systemImage: "plus.circle")
                }
                .axLeaf("FindReplace.Button.AddRule")
                Spacer()
                Menu {
                    Button("Tech terms (English)") { model.importBundledTermPack(named: "tech-terms-en") }
                        .axLeaf("FindReplace.MenuItem.PackTechTermsEn")
                    Button("Termini tecnici (Italiano)") { model.importBundledTermPack(named: "tech-terms-it") }
                        .axLeaf("FindReplace.MenuItem.PackTechTermsIt")
                    Divider()
                    Button("Import from file…") { model.presentTermPackImporter() }
                        .axLeaf("FindReplace.MenuItem.ImportFromFile")
                } label: {
                    Label("Import pack", systemImage: "tray.and.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .axLeaf("FindReplace.Menu.ImportPack")

                Button {
                    model.presentTermPackExporter()
                } label: {
                    Label("Export pack", systemImage: "tray.and.arrow.up")
                }
                .disabled(model.findReplaceRules.isEmpty)
                .axLeaf("FindReplace.Button.ExportPack")
            }

            SettingHelper(text: "Substitutions applied to every new transcript before it's saved. Term packs add curated rules in one click.")
            ResetPaneButton(scope: .findReplace)
        }
    }

    private var visibleRules: [FindReplaceRule] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        var rules = model.findReplaceRules
        if !query.isEmpty {
            rules = rules.filter {
                $0.find.lowercased().contains(query) || $0.replace.lowercased().contains(query)
            }
        }
        switch statusFilter {
        case .all: break
        case .enabled: rules = rules.filter { $0.enabled }
        case .disabled: rules = rules.filter { !$0.enabled }
        }
        switch sortOption {
        case .original: break
        case .findAZ: rules.sort { $0.find.localizedCaseInsensitiveCompare($1.find) == .orderedAscending }
        case .findZA: rules.sort { $0.find.localizedCaseInsensitiveCompare($1.find) == .orderedDescending }
        case .enabledFirst:
            rules.sort { lhs, rhs in
                if lhs.enabled == rhs.enabled { return false }
                return lhs.enabled
            }
        }
        return rules
    }

    private func binding(for id: FindReplaceRule.ID) -> Binding<FindReplaceRule>? {
        guard let idx = model.findReplaceRules.firstIndex(where: { $0.id == id }) else { return nil }
        @Bindable var model = model
        return $model.findReplaceRules[idx]
    }

    private var filterRow: some View {
        HStack(spacing: 8) {
            ForEach(StatusFilter.allCases, id: \.self) { option in
                Chip(title: option.label, isSelected: statusFilter == option, size: .regular, style: .subtle, selectedFill: DS.Color.accent, bordered: false) {
                    statusFilter = option
                }
            }
            Spacer()
            Menu {
                ForEach(SortOption.allCases, id: \.self) { option in
                    Button {
                        sortOption = option
                    } label: {
                        if sortOption == option {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(DS.Font.calloutEmphasized)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort rules")
            .axLeaf("FindReplace.Menu.Sort")
        }
    }

    enum StatusFilter: CaseIterable {
        case all, enabled, disabled

        var label: LocalizedStringKey {
            switch self {
            case .all: return "All"
            case .enabled: return "Enabled"
            case .disabled: return "Disabled"
            }
        }
    }

    enum SortOption: CaseIterable {
        case original, findAZ, findZA, enabledFirst

        var label: LocalizedStringKey {
            switch self {
            case .original: return "Original order"
            case .findAZ: return "Find A→Z"
            case .findZA: return "Find Z→A"
            case .enabledFirst: return "Enabled first"
            }
        }
    }
}

private struct FindReplaceRuleRow: View {
    @Binding var rule: FindReplaceRule
    let isFirst: Bool
    let onDelete: () -> Void

    @State private var cachedRegexError: String?

    private var canEnable: Bool {
        !rule.find.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && regexError == nil
    }

    private var regexError: String? {
        guard rule.regex else { return nil }
        let trimmed = rule.find.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return cachedRegexError
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { rule.enabled && canEnable },
            set: { if canEnable { rule.enabled = $0 } }
        )
    }

    private static func compile(_ pattern: String) -> String? {
        do {
            _ = try NSRegularExpression(pattern: pattern)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst { Divider().padding(.leading, 16) }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Toggle("", isOn: enabledBinding)
                        .labelsHidden()
                        .disabled(!canEnable)
                        .axLeaf("FindReplace.Toggle.RuleEnabled")
                    TextField("find", text: $rule.find)
                        .textFieldStyle(.roundedBorder)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(regexError == nil ? Color.clear : Color.red.opacity(0.8), lineWidth: 1)
                        )
                        .axLeaf("FindReplace.TextField.Find")
                    Text("→").foregroundStyle(.secondary)
                    TextField("replace with", text: $rule.replace).textFieldStyle(.roundedBorder)
                        .axLeaf("FindReplace.TextField.Replace")
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .axLeaf("FindReplace.Button.DeleteRule")
                }
                HStack(spacing: 16) {
                    Toggle("Case-sensitive", isOn: $rule.caseSensitive).toggleStyle(.checkbox)
                        .axLeaf("FindReplace.Toggle.CaseSensitive")
                    Toggle("Regex", isOn: $rule.regex).toggleStyle(.checkbox)
                        .axLeaf("FindReplace.Toggle.Regex")
                }
                .font(.caption)
                if let regexError {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(DS.Color.danger)
                        Text(regexError)
                            .foregroundStyle(DS.Color.danger)
                    }
                    .font(.caption)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .onAppear { cachedRegexError = Self.compile(rule.find) }
        .onChange(of: rule.find) { _, newValue in cachedRegexError = Self.compile(newValue) }
    }
}
