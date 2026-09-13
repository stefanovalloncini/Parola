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

struct RuleEnabledFilterChips: View {
    @Binding var filter: RuleEnabledFilter

    var body: some View {
        HStack(spacing: 4) {
            ForEach(RuleEnabledFilter.allCases, id: \.self) { option in
                Button {
                    filter = option
                } label: {
                    Text(option.title)
                        .font(DS.Font.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .foregroundStyle(filter == option ? Color.white : Color.primary.opacity(0.85))
                        .background(
                            Capsule().fill(filter == option ? DS.Color.accent : Color.secondary.opacity(0.15))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
