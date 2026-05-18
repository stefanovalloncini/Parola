import Foundation
import SwiftUI

enum AppAccent: String, CaseIterable, Identifiable {
    case terracotta
    case blue
    case mint
    case purple
    case pink
    case yellow
    case graphite

    var id: String { rawValue }

    var label: String {
        switch self {
        case .terracotta: return "Terracotta"
        case .blue: return "Blue"
        case .mint: return "Mint"
        case .purple: return "Purple"
        case .pink: return "Pink"
        case .yellow: return "Yellow"
        case .graphite: return "Graphite"
        }
    }

    var color: Color {
        switch self {
        case .terracotta: return Color("AccentColor", bundle: .main)
        case .blue: return Color(red: 0.20, green: 0.49, blue: 0.96)
        case .mint: return Color(red: 0.20, green: 0.70, blue: 0.55)
        case .purple: return Color(red: 0.55, green: 0.35, blue: 0.84)
        case .pink: return Color(red: 0.92, green: 0.38, blue: 0.62)
        case .yellow: return Color(red: 0.96, green: 0.78, blue: 0.20)
        case .graphite: return Color(red: 0.42, green: 0.43, blue: 0.47)
        }
    }

    static let storageKey = "appAccentColor"

    static var current: AppAccent {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let value = AppAccent(rawValue: raw) else {
            return .terracotta
        }
        return value
    }
}
