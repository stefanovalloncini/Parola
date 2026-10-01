import SwiftUI
import ParolaCore

/// The transcript's one way back: to the list it was opened from, or the whole library when it was opened from nowhere.
struct TranscriptBackLink: View {
    @Environment(AppModel.self) private var model

    private var origin: LibraryOrigin { model.transcriptOrigin ?? .all }

    private var personName: String? {
        guard case .person(let id) = origin else { return nil }
        return model.person(id: id)?.name
    }

    var body: some View {
        Button { model.returnToOrigin() } label: {
            HStack(spacing: DS.Spacing.hair) {
                Image(systemName: "chevron.left")
                Text(TranscriptBackCopy.name(for: origin, personName: personName))
                    .lineLimit(1)
            }
            .font(DS.Font.secondary)
            .foregroundStyle(DS.Color.secondaryText)
        }
        .buttonStyle(DSIconChipButtonStyle(fitsLabel: true))
        .modifier(BackHelpModifier(text: TranscriptBackCopy.help(for: origin, personName: personName)))
        .axLeaf("HeaderBar.Button.Back")
    }
}

private struct BackHelpModifier: ViewModifier {
    let text: String

    func body(content: Content) -> some View {
        content.help(text).accessibilityLabel(text)
    }
}

enum TranscriptBackCopy {
    /// The link's own words: the place the list was, and a person's page by the person's name.
    static func name(for origin: LibraryOrigin, personName: String?, bundle: Bundle = .main) -> String {
        if case .person = origin, let personName { return personName }
        return String(localized: String.LocalizationValue(origin.name), bundle: bundle)
    }

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
