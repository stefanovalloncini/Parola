import Foundation

enum AppAccent: String, CaseIterable, Identifiable {
    case slate
    case terracotta
    case blue
    case teal
    case sage
    case indigo
    case mint
    case purple
    case pink
    case yellow
    case graphite

    /// The preset the app opens on, in this enum's terms; `AppAccentTests.presetsAgree` pins the two in sync.
    static var defaultAccent: AppAccent { AppAccent(rawValue: ThemePreset.defaultPreset.rawValue) ?? .slate }

    var id: String { rawValue }

    static let storageKey = "appAccentColor"
}
