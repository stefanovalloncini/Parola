import SwiftUI
import ParolaCore

struct FindReplacePane: View {
    @EnvironmentObject var model: AppModel
    @State private var searchText: String = ""
    @State private var statusFilter: StatusFilter = .all
    @State private var sortOption: SortOption = .original

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            searchField
            filterRow

            SettingsSection {
                let visible = visibleRules
                if model.findReplaceRules.isEmpty {
                    HStack {
                        Text("No rules yet.").foregroundStyle(.secondary).font(.system(size: 13))
                        Spacer()
                    }
                    .padding(16)
                } else if visible.isEmpty {
                    HStack {
                        Text("No rules match.").foregroundStyle(.secondary).font(.system(size: 13))
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
                Spacer()
                Menu {
                    Button("Tech terms (English)") { model.importBundledTermPack(named: "tech-terms-en") }
                    Button("Termini tecnici (Italiano)") { model.importBundledTermPack(named: "tech-terms-it") }
                    Divider()
                    Button("Import from file…") { model.presentTermPackImporter() }
                } label: {
                    Label("Import pack", systemImage: "tray.and.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button {
                    model.presentTermPackExporter()
                } label: {
                    Label("Export pack", systemImage: "tray.and.arrow.up")
                }
                .disabled(model.findReplaceRules.isEmpty)
            }

            SettingHelper(text: "Substitutions applied to every new transcript before it's saved. Term packs add curated rules in one click.")
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
        case .enabledFirst: rules.sort { $0.enabled && !$1.enabled }
        }
        return rules
    }

    private func binding(for id: FindReplaceRule.ID) -> Binding<FindReplaceRule>? {
        guard let idx = model.findReplaceRules.firstIndex(where: { $0.id == id }) else { return nil }
        return $model.findReplaceRules[idx]
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search rules…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.subheadline)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private var filterRow: some View {
        HStack(spacing: 8) {
            ForEach(StatusFilter.allCases, id: \.self) { option in
                FilterChip(title: option.label, isSelected: statusFilter == option) {
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
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort rules")
        }
    }

    enum StatusFilter: CaseIterable {
        case all, enabled, disabled

        var label: String {
            switch self {
            case .all: return "All"
            case .enabled: return "Enabled"
            case .disabled: return "Disabled"
            }
        }
    }

    enum SortOption: CaseIterable {
        case original, findAZ, findZA, enabledFirst

        var label: String {
            switch self {
            case .original: return "Original order"
            case .findAZ: return "Find A→Z"
            case .findZA: return "Find Z→A"
            case .enabledFirst: return "Enabled first"
            }
        }
    }
}

private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? DS.Color.accent : Color.primary.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
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
