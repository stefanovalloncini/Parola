import Foundation

enum DictationIndicatorStyle: String, CaseIterable, Identifiable {
    case nearField
    case overlay
    case notch
    case minimal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nearField: return String(localized: "Near field")
        case .overlay:   return String(localized: "Overlay")
        case .notch:     return String(localized: "Notch")
        case .minimal:   return String(localized: "Minimal")
        }
    }

    var description: String {
        switch self {
        case .nearField: return String(localized: "Compact pill next to the field you're dictating into.")
        case .overlay:   return String(localized: "Floating pill near the bottom of the screen.")
        case .notch:     return String(localized: "Discreet bar pinned under the MacBook notch.")
        case .minimal:   return String(localized: "Tiny dot in the bottom-right corner.")
        }
    }
}
