import Foundation

enum TextInsertionError: LocalizedError {
    case accessibilityDenied

    var errorDescription: String? {
        switch self {
        case .accessibilityDenied:
            return String(localized: "Couldn't insert — the text is on the clipboard, press ⌘V.")
        }
    }
}
