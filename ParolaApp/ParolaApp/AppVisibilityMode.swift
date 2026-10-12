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

    var launchesWithMainWindow: Bool { activationPolicy == .regular }
}

extension AppModel {

    /// `showMenuBarExtra` is derived from the mode, not chosen next to it: this is its only writer.
    func applyAppVisibilityMode() {
        let mode = appVisibilityMode
        showMenuBarExtra = mode.showsMenuBarExtra && !isHeadless
        guard !isHeadless else { return }
        activationPolicyApplier?(mode.activationPolicy)
    }

    /// The stored mode, or — for an install that only ever answered the old menu-bar toggle — that answer.
    nonisolated static func storedVisibilityMode(in defaults: UserDefaults) -> AppVisibilityMode {
        if let raw = defaults.string(forKey: "appVisibilityMode"),
           let stored = AppVisibilityMode(rawValue: raw) {
            return stored
        }
        guard defaults.object(forKey: "showMenuBarExtra") != nil else { return .dockAndMenuBar }
        return defaults.bool(forKey: "showMenuBarExtra") ? .dockAndMenuBar : .dockOnly
    }
}
