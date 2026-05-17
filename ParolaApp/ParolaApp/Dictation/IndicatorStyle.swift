import Foundation

enum DictationIndicatorStyle: String, CaseIterable, Identifiable {
    case overlay
    case notch
    case minimal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .overlay: return "Overlay"
        case .notch:   return "Notch"
        case .minimal: return "Minimal"
        }
    }

    var description: String {
        switch self {
        case .overlay: return "Floating pill near the bottom of the screen."
        case .notch:   return "Discreet bar pinned under the MacBook notch."
        case .minimal: return "Tiny dot in the bottom-right corner."
        }
    }
}
