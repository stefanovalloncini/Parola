import SwiftUI

enum RuleEnabledFilter: CaseIterable {
    case all
    case enabled
    case disabled

    var title: LocalizedStringKey {
        switch self {
        case .all: return "All"
        case .enabled: return "Enabled"
        case .disabled: return "Disabled"
        }
    }

    func includes(_ enabled: Bool) -> Bool {
        switch self {
        case .all: return true
        case .enabled: return enabled
        case .disabled: return !enabled
        }
    }
}

struct RuleEnabledFilterPicker: View {
    @Binding var filter: RuleEnabledFilter
    let leaf: String

    var body: some View {
        Picker("Show", selection: $filter) {
            ForEach(RuleEnabledFilter.allCases, id: \.self) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .axLeaf(leaf)
    }
}
