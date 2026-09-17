import SwiftUI
import ParolaCore

/// The transcript's one way back: to the list it was opened from, or Home when it was opened from nowhere.
struct TranscriptBackLink: View {
    @Environment(AppModel.self) private var model

    private var origin: LibraryOrigin { model.transcriptOrigin ?? .home }

    var body: some View {
        Button { model.returnToOrigin() } label: {
            HStack(spacing: DS.Spacing.hair) {
                Image(systemName: "chevron.left")
                Text(LocalizedStringKey(origin.name))
                    .lineLimit(1)
            }
            .font(DS.Font.secondary)
            .foregroundStyle(DS.Color.secondaryText)
            .padding(.horizontal, DS.Spacing.snug)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                    .fill(DS.Color.surfaceElevated)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .modifier(BackHelpModifier(name: origin.name))
        .axLeaf("HeaderBar.Button.Back")
    }
}

private struct BackHelpModifier: ViewModifier {
    let name: String

    func body(content: Content) -> some View {
        let text = TranscriptBackCopy.help(for: name)
        return content.help(text).accessibilityLabel(text)
    }
}

enum TranscriptBackCopy {
    static func help(for name: String, locale: Locale = AppFormat.locale) -> String {
        let list = String(localized: String.LocalizationValue(name), locale: locale)
        return String(localized: "Back to \(list)", locale: locale)
    }
}
