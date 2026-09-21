import SwiftUI
import ParolaCore

/// The "Send to" submenu, shared by the Transcript menu and the library row's context menu.
/// The model is a parameter, not an environment read: a `CommandMenu` sits outside the window's
/// environment and an `@Environment` read there traps at launch.
struct SendToMenu: View {
    let model: AppModel
    let entryID: LibraryEntry.ID?

    var body: some View {
        Menu("Send to") {
            if model.sendableDestinations.isEmpty {
                Button("Set Up Destinations…") {
                    model.openSettings(route: .sendTo)
                }
                .accessibilityIdentifier("SendTo.MenuItem.SetUp")
            } else {
                ForEach(model.sendableDestinations, id: \.id) { destination in
                    Button {
                        guard let entryID else { return }
                        Task { await model.sendEntry(entryID, to: destination.id) }
                    } label: {
                        Text(verbatim: destination.name)
                    }
                    .disabled(entryID == nil)
                    .accessibilityIdentifier("SendTo.MenuItem.\(destination.id.uuidString)")
                }
            }
        }
    }
}
