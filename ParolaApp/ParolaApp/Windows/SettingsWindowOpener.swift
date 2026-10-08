import AppKit

/// Opens the Settings window through SwiftUI's own Settings… item: on macOS 27 the `showSettingsWindow:` action opens nothing while the window is closed.
@MainActor
enum SettingsWindowOpener {
    static func open() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return }
        open(appMenu: appMenu)
    }

    static func open(appMenu: NSMenu) {
        guard let index = settingsItemIndex(in: appMenu) else { return }
        appMenu.performActionForItem(at: index)
    }

    /// The item carries no identifier of its own; ⌘, is what marks it.
    static func settingsItemIndex(in appMenu: NSMenu) -> Int? {
        appMenu.items.firstIndex { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command }
    }
}
