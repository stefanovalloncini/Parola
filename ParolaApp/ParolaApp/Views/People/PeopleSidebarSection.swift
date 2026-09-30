import SwiftUI
import ParolaCore

/// The people assigned most often, each one a place of its own: the whole library narrowed to them.
struct PeopleSidebarSection: View {
    let people: [Person]
    @Environment(AppModel.self) private var model

    static let rowLimit = 5

    /// The section is for people who are already in use; an empty directory shows nothing at all.
    static func isVisible(showMostUsed: Bool, people: [Person]) -> Bool {
        showMostUsed && !people.isEmpty
    }

    var body: some View {
        Section("People") {
            ForEach(people) { person in
                Label {
                    Text(verbatim: person.name)
                } icon: {
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(DS.speakerColor(for: person.name, colorIndex: person.colorIndex))
                }
                .tag(SidebarItem.person(person.id))
                .contextMenu {
                    Button("Manage People…") { model.showingPeopleSheet = true }
                        .axLeaf("MenuItem.ManagePeople")
                }
                .axLeaf("Row.Person.\(person.name)")
            }
        }
    }
}
