import SwiftUI
import ParolaCore

struct IgnoredSegmentsPane: View {
    @EnvironmentObject var model: AppModel
    @State private var searchText = ""
    @State private var enabledFilter: RuleEnabledFilter = .all
    @State private var sort: IgnoredSegmentsSort = .originalOrder

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SearchPill(text: $searchText, placeholder: "Search patterns…")
                    .frame(maxWidth: 240)
                RuleEnabledFilterChips(filter: $enabledFilter)
                Spacer()
                sortMenu
            }

            SettingsSection {
                if model.ignoredSegmentRules.isEmpty {
                    HStack {
                        Text("No patterns yet.").foregroundStyle(.secondary).font(.body)
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
                        IgnoredRuleRow(
                            rule: $model.ignoredSegmentRules[idx],
                            isFirst: position == 0
                        ) {
                            let id = model.ignoredSegmentRules[idx].id
                            model.ignoredSegmentRules.removeAll { $0.id == id }
                        }
                    }
                }
            }

            Button {
                model.ignoredSegmentRules.append(IgnoredSegmentRule(pattern: ""))
            } label: {
                Label("Add pattern", systemImage: "plus.circle")
            }

            SettingHelper(text: "Segments matching a pattern (case-insensitive, trimmed) are removed before saving.")
            ResetPaneButton(scope: .ignoredSegments)
        }
    }

    private var displayedIndices: [Int] {
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
        return indices
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
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort")
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
            if !isFirst { Divider().padding(.leading, 16) }
            HStack(spacing: 10) {
                Toggle("", isOn: enabledBinding)
                    .labelsHidden()
                    .disabled(!canEnable)
                TextField("e.g. uh, um, hmm", text: $rule.pattern)
                    .textFieldStyle(.roundedBorder)
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
