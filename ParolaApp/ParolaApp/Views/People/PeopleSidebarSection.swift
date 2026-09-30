import SwiftUI
import ParolaCore

/// The PEOPLE rows under LIBRARY: the people assigned most often, each one a filter.
struct PeopleSidebarSection: View {
    @Environment(AppModel.self) private var model

    static let rowLimit = 5

    /// The section is for people who are already in use; an empty directory shows nothing at all.
    static func isVisible(showMostUsed: Bool, people: [Person]) -> Bool {
        showMostUsed && !people.isEmpty
    }

    private var selectedRoute: SidebarRoute {
        SidebarRoute.selected(
            route: model.route,
            searching: model.hasSearchResults,
            filter: model.libraryFilter,
            person: model.personFilter
        )
    }

    var body: some View {
        if Self.isVisible(showMostUsed: model.showMostUsedPeople, people: model.people) {
            SidebarSectionLabel("People")
                .padding(.top, DS.Spacing.regular)

            ForEach(model.mostUsedPeople(limit: Self.rowLimit)) { person in
                SidebarRow(
                    titleVerbatim: person.name,
                    systemImage: "person.crop.circle",
                    isSelected: selectedRoute == .person(person.id)
                ) {
                    model.browsePerson(person.id)
                }
                .accessibilityIdentifier("library.person.\(person.id.uuidString)")
                .axLeaf("Sidebar.Button.Person.\(person.name)")
            }

            SidebarRow(
                title: "Add People…",
                systemImage: "person.badge.plus",
                isSelected: false
            ) {
                model.showingPeopleSheet = true
            }
            .accessibilityIdentifier("library.people.manage")
            .axLeaf("Sidebar.Button.ManagePeople")
        }
    }
}
