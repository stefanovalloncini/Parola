import Foundation
import Observation
import ParolaCore

/// The sessions behind the open transcript windows, keyed by the entry each window shows.
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

    /// Identity-checked: a window reports its close twice, and the second must not take down its replacement.
    @discardableResult
    func release(_ session: EntryWindowSession) -> Bool {
        guard sessions[session.entryID] === session else { return false }
        sessions.removeValue(forKey: session.entryID)
        session.release()
        return true
    }
}
