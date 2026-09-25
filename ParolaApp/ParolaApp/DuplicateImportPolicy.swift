import Foundation

/// What an import does when the library already holds the same bytes.
enum DuplicateImportPolicy: String, CaseIterable, Identifiable {
    case alwaysAsk
    case transcribeAgain
    case openExisting

    var id: String { rawValue }

    /// A batch never prompts, so Ask me drops a known file the way Open the one I have does.
    var batchSkipsDuplicates: Bool { self != .transcribeAgain }

    var label: String {
        switch self {
        case .alwaysAsk: return String(localized: "Ask me")
        case .transcribeAgain: return String(localized: "Transcribe it again")
        case .openExisting: return String(localized: "Open the one I have")
        }
    }
}
