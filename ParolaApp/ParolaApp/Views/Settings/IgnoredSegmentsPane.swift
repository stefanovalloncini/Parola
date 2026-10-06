import SwiftUI
import ParolaCore

struct IgnoredSegmentsPane: View {
    @Environment(AppModel.self) private var model
    @State private var searchText = ""
    @State private var enabledFilter: RuleEnabledFilter = .all
    @State private var sort: IgnoredSegmentsSort = .originalOrder

    var body: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SearchPill(text: $searchText, placeholder: "Search patterns…", leaf: "IgnoredSegments.TextField.Search")
                    .frame(maxWidth: 240)
                RuleEnabledFilterChips(filter: $enabledFilter)
                Spacer()
                sortMenu
            }

            SettingsSection {
                if model.ignoredSegmentRules.isEmpty {
                    InlineEmptyText("No patterns yet")
                } else if displayedRules.isEmpty {
                    HStack {
                        Text("No matches").foregroundStyle(DS.Color.secondaryText).font(DS.Font.body)
                        Spacer()
                    }
                    .padding(DS.Spacing.medium)
                } else {
                    ForEach(Array(displayedRules.enumerated()), id: \.element.id) { position, rule in
                        if let binding = binding(for: rule.id) {
                            IgnoredRuleRow(rule: binding, isFirst: position == 0) {
                                model.ignoredSegmentRules.removeAll { $0.id == rule.id }
                            }
                        }
                    }
                }
            }

            Button {
                searchText = ""
                enabledFilter = .all
                model.ignoredSegmentRules.append(IgnoredSegmentRule(pattern: ""))
            } label: {
                Label("Add Pattern", systemImage: "plus.circle")
            }
            .axLeaf("IgnoredSegments.Button.AddPattern")

            SettingHelper(text: "A segment is removed when its entire text equals a pattern (case-insensitive, trimmed). Catches filler-only segments like “uh” — not words inside sentences. Applies to new transcriptions; saved transcripts don't change.")
            ResetPaneButton(scope: .ignoredSegments)
        }
    }

    private var displayedRules: [IgnoredSegmentRule] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        var indices = model.ignoredSegmentRules.indices.filter { idx in
            let rule = model.ignoredSegmentRules[idx]
            if !enabledFilter.includes(rule.enabled) { return false }
            if query.isEmpty { return true }
            return rule.pattern.lowercased().contains(query)
        }
        switch sort {
        case .originalOrder:
            break
        case .patternAscending:
            indices.sort { pattern(at: $0).localizedCaseInsensitiveCompare(pattern(at: $1)) == .orderedAscending }
        case .patternDescending:
            indices.sort { pattern(at: $0).localizedCaseInsensitiveCompare(pattern(at: $1)) == .orderedDescending }
        case .enabledFirst:
            indices.sort { enabledFirstOrder(lhs: $0, rhs: $1, preferEnabled: true) }
        case .disabledFirst:
            indices.sort { enabledFirstOrder(lhs: $0, rhs: $1, preferEnabled: false) }
        }
        return indices.map { model.ignoredSegmentRules[$0] }
    }

    // Resolved by id on every access: an index captured at render time can go stale
    // when a row is deleted before a pending write lands.
    private func binding(for id: IgnoredSegmentRule.ID) -> Binding<IgnoredSegmentRule>? {
        guard let current = model.ignoredSegmentRules.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { model.ignoredSegmentRules.first(where: { $0.id == id }) ?? current },
            set: { newValue in
                guard let idx = model.ignoredSegmentRules.firstIndex(where: { $0.id == id }) else { return }
                model.ignoredSegmentRules[idx] = newValue
            }
        )
    }

    private func pattern(at index: Int) -> String {
        model.ignoredSegmentRules[index].pattern
    }

    private func enabledFirstOrder(lhs: Int, rhs: Int, preferEnabled: Bool) -> Bool {
        let l = model.ignoredSegmentRules[lhs].enabled
        let r = model.ignoredSegmentRules[rhs].enabled
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
        .axLeaf("IgnoredSegments.Menu.Sort")
    }

    @ViewBuilder private var sortOptions: some View {
        ForEach(IgnoredSegmentsSort.allCases, id: \.self) { option in
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

enum IgnoredSegmentsSort: CaseIterable {
    case originalOrder
    case patternAscending
    case patternDescending
    case enabledFirst
    case disabledFirst

    var title: LocalizedStringKey {
        switch self {
        case .originalOrder: return "Original order"
        case .patternAscending: return "Pattern A→Z"
        case .patternDescending: return "Pattern Z→A"
        case .enabledFirst: return "Enabled first"
        case .disabledFirst: return "Disabled first"
        }
    }
}

private struct IgnoredRuleRow: View {
    @Binding var rule: IgnoredSegmentRule
    let isFirst: Bool
    let onDelete: () -> Void

    private var canEnable: Bool {
        !rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { rule.enabled && canEnable },
            set: { if canEnable { rule.enabled = $0 } }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst { Divider().padding(.leading, DS.Spacing.medium) }
            HStack(spacing: 10) {
                Toggle("Use this rule", isOn: enabledBinding)
                    .labelsHidden()
                    .disabled(!canEnable)
                    .axLeaf("IgnoredSegments.Toggle.RuleEnabled")
                TextField("e.g. uh", text: $rule.pattern)
                    .textFieldStyle(.roundedBorder)
                    .axLeaf("IgnoredSegments.TextField.Pattern")
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .axLeaf("IgnoredSegments.Button.Delete")
            }
            .padding(.horizontal, DS.Spacing.medium)
            .padding(.vertical, DS.Spacing.small)
        }
    }
}
