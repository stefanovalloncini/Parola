import Foundation

enum DictationIndicatorStyle: String, CaseIterable, Identifiable {
    case overlay
    case notch
    case minimal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .overlay: return String(localized: "Overlay")
        case .notch:   return String(localized: "Notch")
        case .minimal: return String(localized: "Minimal")
        }
    }

    var description: String {
        switch self {
        case .overlay: return String(localized: "Floating pill near the bottom of the screen.")
        case .notch:   return String(localized: "Discreet bar pinned under the MacBook notch.")
        case .minimal: return String(localized: "Tiny dot in the bottom-right corner.")
        }
    }
}
