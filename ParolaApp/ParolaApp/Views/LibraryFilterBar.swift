import SwiftUI

enum LibraryDateRangeFilter: String, CaseIterable, Identifiable {
    case all, today, week, month, year
    var id: String { rawValue }
    var label: LocalizedStringKey {
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
    @Binding var languageFilter: String?
    @Binding var dateRangeFilter: LibraryDateRangeFilter
    let labelOptions: [String]
    let languageOptions: [String]

    var body: some View {
        Group {
            if !labelOptions.isEmpty {
                Menu {
                    Button("All labels") { labelFilter = nil }
                        .axLeaf("Filter.MenuItem.AllLabels")
                    Divider()
                    ForEach(labelOptions, id: \.self) { label in
                        Button(label) { labelFilter = label }
                            .axLeaf("Filter.MenuItem.Label.\(label)")
                    }
                } label: {
                    pill(systemImage: "tag", label: labelFilter.map { Text(verbatim: $0) } ?? Text("All labels"))
                }
                .menuStyle(.button)
                .buttonStyle(ChipButtonStyle(isSelected: labelFilter != nil))
                .menuIndicator(.hidden)
                .fixedSize()
                .axLeaf("Filter.Menu.Label")
            }
            if languageOptions.count >= 2 {
                Menu {
                    Button("All languages") { languageFilter = nil }
                        .axLeaf("Filter.MenuItem.AllLanguages")
                    Divider()
                    ForEach(languageOptions, id: \.self) { code in
                        Button(languageName(code)) { languageFilter = code }
                            .axLeaf("Filter.MenuItem.Language.\(code)")
                    }
                } label: {
                    pill(
                        systemImage: "globe",
                        label: languageFilter.map { Text(verbatim: languageName($0)) } ?? Text("All languages")
                    )
                }
                .menuStyle(.button)
                .buttonStyle(ChipButtonStyle(isSelected: languageFilter != nil))
                .menuIndicator(.hidden)
                .fixedSize()
                .axLeaf("Filter.Menu.Language")
            }
            Menu {
                ForEach(LibraryDateRangeFilter.allCases) { option in
                    Button(option.label) { dateRangeFilter = option }
                        .axLeaf("Filter.MenuItem.Date.\(option.rawValue)")
                }
            } label: {
                pill(systemImage: "calendar", label: Text(dateRangeFilter.label))
            }
            .menuStyle(.button)
            .buttonStyle(ChipButtonStyle(isSelected: dateRangeFilter != .all))
            .menuIndicator(.hidden)
            .fixedSize()
            .axLeaf("Filter.Menu.Date")
        }
    }

    private func pill(systemImage: String, label: Text) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            label
        }
    }

    private func languageName(_ code: String) -> String {
        LanguageDisplay.name(for: code) ?? code.uppercased()
    }
}
