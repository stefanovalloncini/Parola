import CoreGraphics
import Foundation
import ParolaCore

enum BurnFontSize: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var pointSize: CGFloat {
        switch self {
        case .small: return 22
        case .medium: return 28
        case .large: return 36
        }
    }

    var displayName: String {
        switch self {
        case .small: return String(localized: "Small")
        case .medium: return String(localized: "Medium")
        case .large: return String(localized: "Large")
        }
    }
}

enum BurnTextColor: String, CaseIterable, Identifiable {
    case white
    case yellow

    var id: String { rawValue }

    var cgColor: CGColor {
        switch self {
        case .white: return CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        case .yellow: return CGColor(red: 1, green: 0.84, blue: 0, alpha: 1)
        }
    }

    var displayName: String {
        switch self {
        case .white: return String(localized: "White")
        case .yellow: return String(localized: "Yellow")
        }
    }
}

extension SubtitleBurner.Style {
    static func make(fontSize: BurnFontSize, textColor: BurnTextColor, outline: Bool) -> SubtitleBurner.Style {
        SubtitleBurner.Style(
            fontSize: fontSize.pointSize,
            textColor: textColor.cgColor,
            strokeWidth: outline ? 4 : 0
        )
    }
}
