import AppKit

/// Where Parola shows up: the Dock icon, the menu bar item, or both.
enum AppVisibilityMode: String, CaseIterable, Identifiable {
    case dockAndMenuBar
    case menuBarOnly
    case dockOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dockAndMenuBar: return String(localized: "Dock and menu bar")
        case .menuBarOnly: return String(localized: "Menu bar only")
        case .dockOnly: return String(localized: "Dock only")
        }
    }

    var activationPolicy: NSApplication.ActivationPolicy {
        switch self {
        case .dockAndMenuBar, .dockOnly: return .regular
        case .menuBarOnly: return .accessory
        }
    }

    var showsMenuBarExtra: Bool {
        switch self {
        case .dockAndMenuBar, .menuBarOnly: return true
        case .dockOnly: return false
        }
    }
}
