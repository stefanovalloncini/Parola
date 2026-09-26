import Foundation
import ParolaCore

extension AppModel {

    /// Hands the scene's `openWindow` to the model, the one thing that can put a window on screen.
    func bindOpenEntryWindow(_ action: @escaping (LibraryEntry.ID) -> Void) {
        openEntryWindowAction = action
    }

    /// The one way a transcript window opens; false when the library has no such entry or no scene can open one.
    @discardableResult
    func openEntryWindow(_ id: LibraryEntry.ID) -> Bool {
        // The session is made before the window so the document is already loading as it draws — but
        // only once the window is certain, or an unopened window would leave a session nobody closes.
        guard libraryEntry(id: id) != nil, let action = openEntryWindowAction else { return false }
        introduction.defer()
        _ = entryWindows.session(for: id, model: self)
        action(id)
        return true
    }

    /// Opening a library row: the main pane, or a window of its own when the setting or Option asks for one.
    @discardableResult
    func openEntryFromLibrary(_ id: LibraryEntry.ID, inNewWindow forced: Bool) -> Bool {
        if forced || openEntriesInNewWindow {
            return openEntryWindow(id)
        }
        return loadEntry(id)
    }

    func entryWindowSession(for id: LibraryEntry.ID) -> EntryWindowSession {
        entryWindows.session(for: id, model: self)
    }

    func releaseEntryWindow(_ session: EntryWindowSession) {
        guard entryWindows.release(session) else { return }
        keyViewerEntryIDs.remove(session.entryID)
    }

    var openEntryWindowIDs: [LibraryEntry.ID] { entryWindows.openIDs }

    // MARK: - Which window the commands act on

    /// Keyed by entry, so two windows trading focus can't leave the flag stuck on.
    func entryWindowKeyChanged(_ id: LibraryEntry.ID, isKey: Bool) {
        if isKey {
            keyViewerEntryIDs.insert(id)
        } else {
            keyViewerEntryIDs.remove(id)
        }
    }

    var keyWindowIsViewer: Bool { !keyViewerEntryIDs.isEmpty }

    var keyViewerSession: EntryWindowSession? {
        keyViewerEntryIDs.sorted().lazy.compactMap { self.entryWindows.existingSession(for: $0) }.first
    }

    /// Off while a viewer holds focus, where these would edit or export something the user can't see.
    var mainTranscriptCommandsEnabled: Bool { hasTranscript && !keyWindowIsViewer }

    var findCommandEnabled: Bool {
        if let session = keyViewerSession { return session.transcript != nil }
        return hasTranscript
    }

    func beginFind() {
        if let session = keyViewerSession {
            session.beginSearch()
        } else {
            if !findIsOpen { toggleFind() }
            findFocusRequests &+= 1
        }
    }

    func goToNextMatchInKeyWindow() {
        if let session = keyViewerSession { session.goToNextMatch() } else { goToNextMatch() }
    }

    func goToPreviousMatchInKeyWindow() {
        if let session = keyViewerSession { session.goToPreviousMatch() } else { goToPreviousMatch() }
    }

    var keyWindowHasMatches: Bool {
        if let session = keyViewerSession { return !session.matches.isEmpty }
        return hasMatches
    }

    var keyWindowFindIsOpen: Bool {
        if let session = keyViewerSession { return session.searchIsOpen }
        return findIsOpen
    }

    var keyWindowHasPlayer: Bool {
        if let session = keyViewerSession { return session.player != nil }
        return player != nil
    }

    var keyWindowIsPlaying: Bool {
        if let session = keyViewerSession { return session.isPlaying }
        return isPlaying
    }

    func togglePlayPauseInKeyWindow() {
        if let session = keyViewerSession { session.togglePlayPause() } else { togglePlayPause() }
    }

    func skipInKeyWindow(by seconds: Double) {
        if let session = keyViewerSession { session.skip(by: seconds) } else { skip(by: seconds) }
    }
}
