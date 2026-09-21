import SwiftUI
import ParolaCore

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
    @Binding var personFilter: UUID?
    let labelOptions: [String]
    let languageOptions: [String]
    let peopleOptions: [Person]

    var body: some View {
        Group {
            if !labelOptions.isEmpty {
                Menu {
                    Button("All Labels") { labelFilter = nil }
                        .axLeaf("Filter.MenuItem.AllLabels")
                    Divider()
                    ForEach(labelOptions, id: \.self) { label in
                        Button(label) { labelFilter = label }
                            .axLeaf("Filter.MenuItem.Label.\(label)")
                    }
                } label: {
                    FilterPillLabel(systemImage: "tag", label: labelFilter.map { Text(verbatim: $0) } ?? Text("All Labels"))
                }
                .menuStyle(.button)
                .buttonStyle(ChipButtonStyle(isSelected: labelFilter != nil))
                .menuIndicator(.hidden)
                .fixedSize()
                .axLeaf("Filter.Menu.Label")
            }
            if !peopleOptions.isEmpty {
                Menu {
                    Button("All People") { personFilter = nil }
                        .axLeaf("Filter.MenuItem.AllPeople")
                    Divider()
                    ForEach(peopleOptions) { person in
                        Button(person.name) { personFilter = person.id }
                            .axLeaf("Filter.MenuItem.Person.\(person.name)")
                    }
                } label: {
                    FilterPillLabel(
                        systemImage: "person",
                        label: selectedPerson.map { Text(verbatim: $0.name) } ?? Text("All People")
                    )
                }
                .menuStyle(.button)
                .buttonStyle(ChipButtonStyle(isSelected: personFilter != nil))
                .menuIndicator(.hidden)
                .fixedSize()
                .axLeaf("Filter.Menu.Person")
            }
            if languageOptions.count >= 2 {
                Menu {
                    Button("All Languages") { languageFilter = nil }
                        .axLeaf("Filter.MenuItem.AllLanguages")
                    Divider()
                    ForEach(languageOptions, id: \.self) { code in
                        Button(languageName(code)) { languageFilter = code }
                            .axLeaf("Filter.MenuItem.Language.\(code)")
                    }
                } label: {
                    FilterPillLabel(
                        systemImage: "globe",
                        label: languageFilter.map { Text(verbatim: languageName($0)) } ?? Text("All Languages")
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
                FilterPillLabel(systemImage: "calendar", label: Text(dateRangeFilter.label))
            }
            .menuStyle(.button)
            .buttonStyle(ChipButtonStyle(isSelected: dateRangeFilter != .all))
            .menuIndicator(.hidden)
            .fixedSize()
            .axLeaf("Filter.Menu.Date")
        }
    }

    private var selectedPerson: Person? {
        personFilter.flatMap { id in peopleOptions.first { $0.id == id } }
    }

    private func languageName(_ code: String) -> String {
        LanguageDisplay.name(for: code) ?? code.uppercased()
    }
}

/// The label every filter pull-down wears: a glyph and what the list is filtered to.
struct FilterPillLabel: View {
    let systemImage: String
    let label: Text

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            label
        }
    }
}
