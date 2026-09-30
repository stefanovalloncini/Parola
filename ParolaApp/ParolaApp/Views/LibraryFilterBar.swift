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

/// The Labels, People, Language and date pull-downs: header menus on a wide window, submenus of More on a narrow one.
struct LibraryFilterBar: View {
    @Environment(AppModel.self) private var model
    @Binding var labelFilter: String?
    @Binding var languageFilter: String?
    @Binding var dateRangeFilter: LibraryDateRangeFilter
    @Binding var personFilter: UUID?
    let labelOptions: [String]
    let languageOptions: [String]
    let peopleOptions: [Person]

    /// A category with no speakers (Dictations) must not make an active person filter disappear.
    static func showsPersonFilter(peopleOptions: [Person], personFilter: UUID?) -> Bool {
        !peopleOptions.isEmpty || personFilter != nil
    }

    /// One long label or name shouldn't be enough to send the other menus into More.
    static let valueCharacterCap = 24

    static func capped(_ value: String) -> String {
        value.count <= valueCharacterCap ? value : String(value.prefix(valueCharacterCap - 1)) + "…"
    }

    static func isCut(_ value: String) -> Bool {
        value.count > valueCharacterCap
    }

    var isFiltering: Bool {
        labelFilter != nil || languageFilter != nil || dateRangeFilter != .all || personFilter != nil
    }

    var body: some View {
        Group {
            if !labelOptions.isEmpty || labelFilter != nil {
                labelsMenu
            }
            if Self.showsPersonFilter(peopleOptions: peopleOptions, personFilter: personFilter) {
                peopleMenu
            }
            if languageOptions.count >= 2 || languageFilter != nil {
                languageMenu
            }
            dateMenu
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
            LibraryHeaderMenuLabel(rest: Text("Labels"), active: labelFilter.map { Text("Labels: \(Self.capped($0))") })
        }
        .libraryHeaderMenu()
        .modifier(FullValue(text: labelFilter.flatMap { Self.isCut($0) ? Text("Labels: \($0)") : nil }))
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
            LibraryHeaderMenuLabel(rest: Text("People"), active: selectedName.map { Text("People: \(Self.capped($0))") })
        }
        .libraryHeaderMenu()
        .modifier(FullValue(text: selectedName.flatMap { Self.isCut($0) ? Text("People: \($0)") : nil }))
        .axLeaf("Menu.People")
    }

    private var languageMenu: some View {
        Menu {
            Button("All Languages") { languageFilter = nil }
                .axLeaf("MenuItem.AllLanguages")
            Divider()
            ForEach(languageOptions, id: \.self) { code in
                Toggle(isOn: choosing(code, in: $languageFilter)) { Text(verbatim: languageName(code)) }
                    .axLeaf("MenuItem.Language.\(code)")
            }
        } label: {
            let name = languageFilter.map(languageName)
            LibraryHeaderMenuLabel(rest: Text("Language"), active: name.map { Text("Language: \(Self.capped($0))") })
        }
        .libraryHeaderMenu()
        .modifier(FullValue(text: languageFilter.map(languageName).flatMap { Self.isCut($0) ? Text("Language: \($0)") : nil }))
        .axLeaf("Menu.Language")
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
                .foregroundStyle(dateRangeFilter == .all ? DS.Color.primaryText : DS.Color.accentInk)
        }
        .libraryHeaderMenu()
        .axLeaf("Menu.Date")
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

/// What a header menu reads: the menu's name at rest, what it keeps once it filters, in the accent's ink.
private struct LibraryHeaderMenuLabel: View {
    let rest: Text
    let active: Text?

    var body: some View {
        if let active {
            active.foregroundStyle(DS.Color.accentInk)
        } else {
            rest.foregroundStyle(DS.Color.primaryText)
        }
    }
}

/// A value cut short in the menu keeps all of itself in the tooltip and in what VoiceOver reads.
private struct FullValue: ViewModifier {
    let text: Text?

    func body(content: Content) -> some View {
        if let text {
            content.help(text).accessibilityLabel(text)
        } else {
            content
        }
    }
}

extension View {
    /// Plain text and a chevron, sized to their words: inside More the same menus render as submenus and ignore it.
    func libraryHeaderMenu() -> some View {
        menuStyle(.button)
            .buttonStyle(.borderless)
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
