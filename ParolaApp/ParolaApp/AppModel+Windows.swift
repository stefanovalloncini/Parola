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

    /// Opening a library row: the main pane, or a window of its own when the user asked for that
    /// with the setting or by holding Option.
    func openEntryFromLibrary(_ id: LibraryEntry.ID, inNewWindow forced: Bool) {
        if forced || openEntriesInNewWindow {
            openEntryWindow(id)
        } else {
            loadEntry(id)
        }
    }

    func entryWindowSession(for id: LibraryEntry.ID) -> EntryWindowSession {
        entryWindows.session(for: id, model: self)
    }

    func releaseEntryWindow(_ id: LibraryEntry.ID) {
        keyViewerEntryIDs.remove(id)
        entryWindows.release(id)
    }

    var openEntryWindowIDs: [LibraryEntry.ID] { entryWindows.openIDs }

    // MARK: - Which window the commands act on

    /// Set by each transcript window as it takes or loses key. Keyed by entry so two windows
    /// trading focus can't leave the flag stuck on.
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

    /// Commands that act on the transcript in the main window: off while a viewer holds focus,
    /// where they would edit or export something the user can't see.
    var mainTranscriptCommandsEnabled: Bool { hasTranscript && !keyWindowIsViewer }

    var findCommandEnabled: Bool {
        if let session = keyViewerSession { return session.transcript != nil }
        return hasTranscript
    }

    func beginFind() {
        if let session = keyViewerSession {
            session.toggleSearch()
        } else {
            toggleFind()
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
