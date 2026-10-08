import SwiftUI

enum RuleListSort: CaseIterable {
    case original, ascending, descending, enabledFirst, disabledFirst

    var title: LocalizedStringKey {
        switch self {
        case .original: return "Original order"
        case .ascending: return "A→Z"
        case .descending: return "Z→A"
        case .enabledFirst: return "Enabled first"
        case .disabledFirst: return "Disabled first"
        }
    }
}

/// The search, filter and sort a rule-list pane applies to its rules.
struct RuleListQuery {
    var search = ""
    var filter: RuleEnabledFilter = .all
    var sort: RuleListSort = .original

    static let toolbarThreshold = 8

    var narrowsTheList: Bool {
        !search.trimmingCharacters(in: .whitespaces).isEmpty || filter != .all || sort != .original
    }

    /// A short list needs no search; the toolbar stays while it still narrows the list, so nothing hides unseen.
    func showsToolbar(ruleCount: Int) -> Bool {
        ruleCount >= Self.toolbarThreshold || narrowsTheList
    }

    /// Search matches any field; sorting goes by the first field, ties in list order.
    func arrange<Rule>(_ rules: [Rule], fields: (Rule) -> [String], isEnabled: (Rule) -> Bool) -> [Rule] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        var indices = rules.indices.filter { index in
            let rule = rules[index]
            guard filter.includes(isEnabled(rule)) else { return false }
            return query.isEmpty || fields(rule).contains { $0.lowercased().contains(query) }
        }
        let keys = rules.map { fields($0).first ?? "" }
        switch sort {
        case .original:
            break
        case .ascending, .descending:
            let wanted: ComparisonResult = sort == .ascending ? .orderedAscending : .orderedDescending
            indices.sort { lhs, rhs in
                let order = keys[lhs].localizedCaseInsensitiveCompare(keys[rhs])
                return order == .orderedSame ? lhs < rhs : order == wanted
            }
        case .enabledFirst, .disabledFirst:
            let first = sort == .enabledFirst
            indices.sort { lhs, rhs in
                let l = isEnabled(rules[lhs]), r = isEnabled(rules[rhs])
                return l == r ? lhs < rhs : l == first
            }
        }
        return indices.map { rules[$0] }
    }

    /// A fresh rule starts empty, so a live search or the Disabled filter would hide it.
    mutating func showNewRule() {
        search = ""
        filter = .all
    }
}

/// Search, the enabled filter and sort, on one line above the list they narrow.
struct RuleListToolbar: View {
    @Binding var query: RuleListQuery
    let placeholder: LocalizedStringKey
    let leafPrefix: String

    var body: some View {
        HStack(spacing: 8) {
            SearchPill(text: $query.search, placeholder: placeholder, leaf: "\(leafPrefix).TextField.Search")
                .frame(maxWidth: 240)
            RuleEnabledFilterPicker(filter: $query.filter, leaf: "\(leafPrefix).Picker.Filter")
            Spacer()
            RuleListSortMenu(leaf: "\(leafPrefix).Menu.Sort") {
                ForEach(RuleListSort.allCases, id: \.self) { option in
                    Button {
                        query.sort = option
                    } label: {
                        if query.sort == option {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            }
        }
    }
}

/// A native pull-down that shows only the sort glyph, named for VoiceOver.
struct RuleListSortMenu<Options: View>: View {
    var title: LocalizedStringKey = "Sort"
    let leaf: String
    @ViewBuilder var options: Options

    var body: some View {
        Menu {
            options
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(title)
        .accessibilityRepresentation {
            Menu(title) { options }
        }
        .axLeaf(leaf)
    }
}
