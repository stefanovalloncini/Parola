import SwiftUI

enum LibraryDateRangeFilter: String, CaseIterable, Identifiable {
    case all, today, week, month, year
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "Any time"
        case .today: return "Today"
        case .week: return "Last 7 days"
        case .month: return "Last 30 days"
        case .year: return "Last year"
        }
    }
    var cutoff: Date? {
        let cal = Calendar.current
        switch self {
        case .all: return nil
        case .today: return cal.startOfDay(for: Date())
        case .week: return cal.date(byAdding: .day, value: -7, to: Date())
        case .month: return cal.date(byAdding: .day, value: -30, to: Date())
        case .year: return cal.date(byAdding: .year, value: -1, to: Date())
        }
    }
}

struct LibraryFilterBar: View {
    @Binding var labelFilter: String?
    @Binding var dateRangeFilter: LibraryDateRangeFilter
    let labelOptions: [String]

    var body: some View {
        Group {
            if !labelOptions.isEmpty {
                Menu {
                    Button("All labels") { labelFilter = nil }
                    Divider()
                    ForEach(labelOptions, id: \.self) { label in
                        Button(label) { labelFilter = label }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "tag")
                        Text(labelFilter ?? "All labels")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(labelFilter == nil ? .secondary : DS.Color.accent)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            Menu {
                ForEach(LibraryDateRangeFilter.allCases) { option in
                    Button(option.label) { dateRangeFilter = option }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                    Text(dateRangeFilter.label)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(dateRangeFilter == .all ? .secondary : DS.Color.accent)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}
