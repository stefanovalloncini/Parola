import Foundation
import ParolaCore

extension AppModel {

    /// Hands the scene's `openWindow` to the model, which the menu, the library rows and the bridge
    /// all reach through ``openEntryWindow(_:)``.
    func bindOpenEntryWindow(_ action: @escaping (LibraryEntry.ID) -> Void) {
        openEntryWindowAction = action
    }

    /// The one way a transcript window opens. An id the library does not hold opens nothing.
    /// The session is made here rather than when the view appears, so the document is already
    /// loading as the window draws and `openEntryWindowIDs` answers for it straight away.
    func openEntryWindow(_ id: LibraryEntry.ID) {
        guard libraryEntry(id: id) != nil else { return }
        introduction.defer()
        _ = entryWindows.session(for: id, model: self)
        openEntryWindowAction?(id)
    }

    func entryWindowSession(for id: LibraryEntry.ID) -> EntryWindowSession {
        entryWindows.session(for: id, model: self)
    }

    func releaseEntryWindow(_ id: LibraryEntry.ID) {
        entryWindows.release(id)
    }

    var openEntryWindowIDs: [LibraryEntry.ID] { entryWindows.openIDs }
}
