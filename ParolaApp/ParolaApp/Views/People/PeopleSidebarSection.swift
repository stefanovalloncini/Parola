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
                .badge(model.transcriptCount(of: person))
                .tag(SidebarItem.person(person.id))
                .contextMenu { PersonRowMenu(model: model, person: person) }
                .axLeaf("Row.Person.\(person.name)")
            }
            if model.people.count > people.count {
                Button { model.showingPeopleSheet = true } label: {
                    Label("All People…", systemImage: "ellipsis.circle")
                        .foregroundStyle(DS.Color.secondaryText)
                }
                .buttonStyle(.plain)
                .axLeaf("Row.AllPeople")
            }
        }
    }
}

enum PeopleSheetRequest: Equatable {
    case rename(UUID)
    case delete(UUID)
}

/// A sidebar person's right-click: what can be done to them, then the whole directory.
struct PersonRowMenu: View {
    let model: AppModel
    let person: Person

    var body: some View {
        Button("Show Transcripts") { model.browsePerson(person.id) }
            .axLeaf("MenuItem.ShowTranscripts")
        Button("Rename…") { model.managePerson(.rename(person.id)) }
            .axLeaf("MenuItem.Rename")
        Toggle("This Is Me", isOn: Binding(
            get: { person.isMe },
            set: { isMe in Task { await model.setMePerson(isMe ? person.id : nil) } }
        ))
        .axLeaf("MenuItem.ThisIsMe")
        Button("Delete…") { model.managePerson(.delete(person.id)) }
            .axLeaf("MenuItem.Delete")
        Divider()
        Button("Manage People…") { model.showingPeopleSheet = true }
            .axLeaf("MenuItem.ManagePeople")
    }
}
