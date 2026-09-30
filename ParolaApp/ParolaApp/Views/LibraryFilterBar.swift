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

/// The Labels, People, Language and date pull-downs: chips in the header, submenus of More once they fold.
struct LibraryFilterBar: View {
    enum Presentation {
        /// A chip names its dimension at rest and only the value it keeps once it filters.
        case chips
        /// A submenu of More keeps the dimension's name in front of the value.
        case submenus
        /// Language alone, the submenu More keeps for it while the chips are out.
        case language
    }

    @Environment(AppModel.self) private var model
    @Binding var labelFilter: String?
    @Binding var languageFilter: String?
    @Binding var dateRangeFilter: LibraryDateRangeFilter
    @Binding var personFilter: UUID?
    let labelOptions: [String]
    let languageOptions: [String]
    let peopleOptions: [Person]
    var presentation: Presentation = .chips

    /// A category with no speakers (Dictations) must not make an active person filter disappear.
    static func showsPersonFilter(peopleOptions: [Person], personFilter: UUID?) -> Bool {
        !peopleOptions.isEmpty || personFilter != nil
    }

    /// One long label or name shouldn't be enough to send the other menus into More.
    static let valueCharacterCap = 24

    static func capped(_ value: String) -> String {
        value.count <= valueCharacterCap ? value : String(value.prefix(valueCharacterCap - 1)) + "…"
    }

    var isFiltering: Bool {
        labelFilter != nil || languageFilter != nil || dateRangeFilter != .all || personFilter != nil
    }

    /// A chip only while it filters; in More once the page holds two languages, or one is already picked.
    static func showsLanguage(in presentation: Presentation, optionCount: Int, filtering: Bool) -> Bool {
        switch presentation {
        case .chips: return filtering
        case .submenus, .language: return optionCount >= 2 || filtering
        }
    }

    var showsLanguage: Bool {
        Self.showsLanguage(in: presentation, optionCount: languageOptions.count, filtering: languageFilter != nil)
    }

    func presented(as presentation: Presentation) -> LibraryFilterBar {
        var copy = self
        copy.presentation = presentation
        return copy
    }

    var body: some View {
        Group {
            if presentation != .language {
                if !labelOptions.isEmpty || labelFilter != nil {
                    labelsMenu
                }
                if Self.showsPersonFilter(peopleOptions: peopleOptions, personFilter: personFilter) {
                    peopleMenu
                }
            }
            if showsLanguage {
                languageMenu
            }
            if presentation != .language {
                dateMenu
            }
        }
    }

    private var labelsMenu: some View {
        Menu {
            Button("All Labels") { labelFilter = nil }
                .axLeaf("MenuItem.AllLabels")
            Divider()
            ForEach(labelOptions, id: \.self) { label in
                Toggle(isOn: choosing(label, in: $labelFilter)) { Text(verbatim: label) }
                    .axLeaf("MenuItem.Label.\(label)")
            }
        } label: {
            title(Text("Labels"), value: labelFilter) { Text("Labels: \($0)") }
        }
        .libraryHeaderChip(isActive: labelFilter != nil)
        .modifier(FilterValue(name: Text("Labels"), value: labelFilter.map { Text("Labels: \($0)") }))
        .axLeaf("Menu.Labels")
    }

    private var peopleMenu: some View {
        Menu {
            Button("All People") { personFilter = nil }
                .axLeaf("MenuItem.AllPeople")
            if !peopleOptions.isEmpty {
                Divider()
                ForEach(peopleOptions) { person in
                    Toggle(isOn: choosing(person.id, in: $personFilter)) { Text(verbatim: person.name) }
                        .axLeaf("MenuItem.Person.\(person.name)")
                }
            }
        } label: {
            title(Text("People"), value: selectedName) { Text("People: \($0)") }
        }
        .libraryHeaderChip(isActive: personFilter != nil)
        .modifier(FilterValue(name: Text("People"), value: selectedName.map { Text("People: \($0)") }))
        .axLeaf("Menu.People")
    }

    private var languageMenu: some View {
        let name = languageFilter.map(languageName)
        return Menu {
            Button("All Languages") { languageFilter = nil }
                .axLeaf("MenuItem.AllLanguages")
            Divider()
            ForEach(languageOptions, id: \.self) { code in
                Toggle(isOn: choosing(code, in: $languageFilter)) { Text(verbatim: languageName(code)) }
                    .axLeaf("MenuItem.Language.\(code)")
            }
        } label: {
            title(Text("Language"), value: name) { Text("Language: \($0)") }
        }
        .libraryHeaderChip(isActive: languageFilter != nil)
        .modifier(FilterValue(name: Text("Language"), value: name.map { Text("Language: \($0)") }))
        .axLeaf(presentation == .chips ? "Menu.ActiveLanguage" : "Menu.Language")
    }

    private var dateMenu: some View {
        Menu {
            ForEach(LibraryDateRangeFilter.allCases) { option in
                Toggle(isOn: Binding(get: { dateRangeFilter == option }, set: { if $0 { dateRangeFilter = option } })) {
                    Text(option.label)
                }
                .axLeaf("MenuItem.Date.\(option.rawValue)")
            }
        } label: {
            Text(dateRangeFilter.label)
        }
        .libraryHeaderChip(isActive: dateRangeFilter != .all)
        .axLeaf("Menu.Date")
    }

    /// The dimension at rest; once it filters, the value on a chip and the dimension with its value in a submenu.
    private func title(_ name: Text, value: String?, prefixed: (String) -> Text) -> Text {
        guard let value else { return name }
        let shown = Self.capped(value)
        switch presentation {
        case .chips: return Text(verbatim: shown)
        case .submenus, .language: return prefixed(shown)
        }
    }

    /// A checkmark on the one value the list is narrowed to; picking it again clears the filter.
    private func choosing<Value: Equatable>(_ value: Value, in filter: Binding<Value?>) -> Binding<Bool> {
        Binding(get: { filter.wrappedValue == value }, set: { filter.wrappedValue = $0 ? value : nil })
    }

    /// Falls back to the full directory: a filtered person can be absent from this category's own options.
    private var selectedName: String? {
        guard let personFilter else { return nil }
        return (peopleOptions.first { $0.id == personFilter } ?? model.person(id: personFilter))?.name
    }

    private func languageName(_ code: String) -> String {
        LanguageDisplay.name(for: code) ?? code.uppercased()
    }
}

/// The chip shows only the value; the tooltip and VoiceOver get the dimension's name in front of all of it.
private struct FilterValue: ViewModifier {
    let name: Text
    let value: Text?

    func body(content: Content) -> some View {
        content
            .help(value ?? Text(verbatim: ""))
            .accessibilityLabel(value ?? name)
    }
}

extension View {
    /// A small bordered capsule, neutral until it narrows the list; inside More the same menus render as submenus and ignore it.
    func libraryHeaderChip(isActive: Bool = false) -> some View {
        menuStyle(.button)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .tint(isActive ? DS.Color.accent : nil)
            .fixedSize()
    }
}

/// A chip pull-down's label: a glyph and what the list is filtered to.
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
