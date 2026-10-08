import SwiftUI
import ParolaCore

/// The transcript's one way back, at the toolbar's leading edge: to the list it was opened from, or the whole library when it was opened from nowhere.
struct TranscriptBackLink: View {
    @Environment(AppModel.self) private var model

    private var origin: LibraryOrigin { model.transcriptOrigin ?? .all }

    private var personName: String? {
        guard case .person(let id) = origin else { return nil }
        return model.person(id: id)?.name
    }

    var body: some View {
        let help = TranscriptBackCopy.help(for: origin, personName: personName)
        Button { model.returnToOrigin() } label: {
            Label(help, systemImage: "chevron.left")
        }
        .help(help)
        .axLeaf("Toolbar.Transcript.Button.Back")
    }
}

enum TranscriptBackCopy {
    /// Whole sentences per destination: Italian needs the article, which an interpolated name cannot carry; a person's name takes none.
    static func help(for origin: LibraryOrigin, personName: String? = nil, bundle: Bundle = .main) -> String {
        switch origin {
        case .person:
            guard let personName else { return help(for: .all, bundle: bundle) }
            return String(localized: "Back to \(personName)", bundle: bundle)
        case .all: return String(localized: "Back to Library", bundle: bundle)
        case .search: return String(localized: "Back to Results", bundle: bundle)
        case .category(.transcription): return String(localized: "Back to Transcriptions", bundle: bundle)
        case .category(.meeting): return String(localized: "Back to Meetings", bundle: bundle)
        case .category(.dictation): return String(localized: "Back to Dictations", bundle: bundle)
        }
    }
}
