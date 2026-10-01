import AppKit

/// SwiftUI redraws the Recording menu as the take changes, but AppKit takes a drawing only when the menu's delegate is asked, as the menu opens and never before a key is matched; so each drawing asks it.
@MainActor
final class RecordingMenuRefresher {
    static let shared = RecordingMenuRefresher()

    private let menu: @MainActor () -> NSMenu?
    private var asking = false
    private var refreshing = false

    init(menu: @escaping @MainActor () -> NSMenu? = RecordingMenuRefresher.recordingMenu) {
        self.menu = menu
    }

    static func recordingMenu() -> NSMenu? {
        let title = String(localized: "Recording")
        return NSApp.mainMenu?.items.first { $0.title == title }?.submenu
    }

    /// Called from the menu's body; the delegate is asked once the update that drew it is over, at most once a turn, and a drawing the refresh itself causes asks nothing more.
    func menuDrew() {
        guard !refreshing, !asking else { return }
        asking = true
        Task { @MainActor [weak self] in self?.refresh() }
    }

    private func refresh() {
        asking = false
        guard let menu = menu() else { return }
        refreshing = true
        menu.delegate?.menuNeedsUpdate?(menu)
        refreshing = false
    }
}
