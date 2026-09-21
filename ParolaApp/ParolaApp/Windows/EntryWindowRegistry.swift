import Foundation
import Observation
import ParolaCore

/// The sessions behind the open transcript windows, keyed by the entry each window shows. A second
/// window on the same entry is the same window, so the same session answers for it.
@MainActor
@Observable
final class EntryWindowRegistry {
    private(set) var sessions: [LibraryEntry.ID: EntryWindowSession] = [:]

    var openIDs: [LibraryEntry.ID] { sessions.keys.sorted() }

    func session(for entryID: LibraryEntry.ID, model: AppModel) -> EntryWindowSession {
        if let existing = sessions[entryID] { return existing }
        let session = EntryWindowSession(entryID: entryID, model: model)
        sessions[entryID] = session
        return session
    }

    func existingSession(for entryID: LibraryEntry.ID) -> EntryWindowSession? {
        sessions[entryID]
    }

    func release(_ entryID: LibraryEntry.ID) {
        sessions.removeValue(forKey: entryID)?.release()
    }
}
