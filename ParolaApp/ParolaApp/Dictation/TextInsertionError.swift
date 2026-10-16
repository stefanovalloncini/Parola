import Foundation

enum TextInsertionError: LocalizedError {
    case accessibilityDenied
    case targetChanged

    var errorDescription: String? {
        switch self {
        case .accessibilityDenied:
            return String(localized: "Couldn't insert — the text is on the clipboard, press ⌘V.")
        case .targetChanged:
            return String(localized: "Copied: you switched apps")
        }
    }
}
