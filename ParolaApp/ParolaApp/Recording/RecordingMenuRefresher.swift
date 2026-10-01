import AppKit

/// SwiftUI redraws the Recording menu as the take changes, but AppKit takes a drawing only when the menu's delegate is asked, as the menu opens and never before a key is matched; so each drawing asks it.
@MainActor
enum RecordingMenuRefresher {
    private static var asking = false

    static func recordingMenu() -> NSMenu? {
        let title = String(localized: "Recording")
        return NSApp.mainMenu?.items.first { $0.title == title }?.submenu
    }

    /// Called from the menu's body; the delegate is asked once the update that drew it is over, at most once a turn.
    static func menuDrew() {
        guard !asking else { return }
        asking = true
        Task { @MainActor in
            asking = false
            guard let menu = recordingMenu() else { return }
            menu.delegate?.menuNeedsUpdate?(menu)
        }
    }
}
