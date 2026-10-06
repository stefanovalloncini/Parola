import SwiftUI
import ParolaCore

/// The people a menu's first ten leave out, one level down.
struct MorePeopleMenu: View {
    let people: [Person]
    let pick: (Person) -> Void

    var body: some View {
        if !people.isEmpty {
            Menu("More People") {
                ForEach(people) { person in
                    Button(person.name) { pick(person) }
                }
            }
        }
    }
}
