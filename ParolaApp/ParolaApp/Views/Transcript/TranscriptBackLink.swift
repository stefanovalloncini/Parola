import SwiftUI
import ParolaCore

/// The transcript's one way back: to the list it was opened from, or the whole library when it was opened from nowhere.
struct TranscriptBackLink: View {
    @Environment(AppModel.self) private var model

    private var origin: LibraryOrigin { model.transcriptOrigin ?? .all }

    var body: some View {
        Button { model.returnToOrigin() } label: {
            HStack(spacing: DS.Spacing.hair) {
                Image(systemName: "chevron.left")
                Text(LocalizedStringKey(origin.name))
                    .lineLimit(1)
            }
            .font(DS.Font.secondary)
            .foregroundStyle(DS.Color.secondaryText)
        }
        .buttonStyle(DSIconChipButtonStyle(fitsLabel: true))
        .modifier(BackHelpModifier(origin: origin))
        .axLeaf("HeaderBar.Button.Back")
    }
}

private struct BackHelpModifier: ViewModifier {
    let origin: LibraryOrigin

    func body(content: Content) -> some View {
        let text = TranscriptBackCopy.help(for: origin)
        return content.help(text).accessibilityLabel(text)
    }
}

enum TranscriptBackCopy {
    /// Whole sentences per destination: Italian needs the article, which an interpolated name cannot carry.
    static func help(for origin: LibraryOrigin, bundle: Bundle = .main) -> String {
        switch origin {
        case .all: return String(localized: "Back to Library", bundle: bundle)
        case .search: return String(localized: "Back to Results", bundle: bundle)
        case .category(.transcription): return String(localized: "Back to Transcriptions", bundle: bundle)
        case .category(.meeting): return String(localized: "Back to Meetings", bundle: bundle)
        case .category(.dictation): return String(localized: "Back to Dictations", bundle: bundle)
        }
    }
}
