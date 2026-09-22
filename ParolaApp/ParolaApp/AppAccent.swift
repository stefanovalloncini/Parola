import Foundation
import SwiftUI

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

    static let defaultAccent: AppAccent = .slate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .slate: return "Slate"
        case .terracotta: return "Terracotta"
        case .blue: return "Blue"
        case .teal: return "Teal"
        case .sage: return "Sage"
        case .indigo: return "Indigo"
        case .mint: return "Mint"
        case .purple: return "Purple"
        case .pink: return "Pink"
        case .yellow: return "Yellow"
        case .graphite: return "Graphite"
        }
    }

    /// The preset sharing this raw value owns the values; reading the asset catalog here let the two drift.
    var preset: ThemePreset { ThemePreset(rawValue: rawValue) ?? .defaultPreset }

    var color: Color { preset.accent.color }

    static let storageKey = "appAccentColor"

    static var current: AppAccent {
        guard let raw = DefaultsStore.current.string(forKey: storageKey),
              let value = AppAccent(rawValue: raw) else {
            return .defaultAccent
        }
        return value
    }
}
