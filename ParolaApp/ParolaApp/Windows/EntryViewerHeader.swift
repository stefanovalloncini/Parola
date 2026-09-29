import SwiftUI
import ParolaCore

struct EntryViewerHeader: View {
    let session: EntryWindowSession

    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: DS.Spacing.small) {
            VStack(alignment: .leading, spacing: DS.Spacing.hair) {
                Text(verbatim: session.title)
                    .font(DS.Font.heading)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(DS.Font.secondary)
                        .foregroundStyle(DS.Color.secondaryText)
                        .lineLimit(1)
                }
            }

            if let language = languageLabel {
                Text(verbatim: language)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.accentInk)
                    .padding(.horizontal, DS.Spacing.snug)
                    .padding(.vertical, DS.Spacing.hair)
                    .background(Capsule().fill(DS.Color.accentWash))
                    .axLeaf("Label.Language")
            }

            Spacer(minLength: DS.Spacing.small)

            HStack(spacing: 0) {
                Button { session.toggleSearch() } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(GlyphButtonStyle(tinted: true))
                .help("Find in this transcript")
                .accessibilityLabel("Find in this transcript")
                .axLeaf("Button.Search")

                Button { session.showsInfo.toggle() } label: {
                    Image(systemName: session.showsInfo ? "sidebar.right" : "info.circle")
                }
                .buttonStyle(GlyphButtonStyle(tinted: true))
                .help(session.showsInfo ? "Hide info" : "Show info")
                .accessibilityLabel("Info")
                .axLeaf("Toggle.Info")
            }

            Button("Copy Transcript") { session.copyTranscript() }
                .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                .disabled(session.transcript == nil)
                .axLeaf("Button.CopyTranscript")
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.small)
        .chromeSurface()
    }

    private var subtitle: String? {
        var parts: [String] = []
        if session.durationSeconds > 0 {
            parts.append(Timecode.format(session.durationSeconds.rounded()))
        }
        if let name = session.transcript?.modelName, let label = LibraryEntryDisplay.modelName(raw: name) {
            parts.append(label)
        }
        parts.append(SegmentCount.label(session.transcript?.segments.count ?? 0))
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var languageLabel: String? {
        LanguageDisplay.name(for: session.transcript?.language)
    }
}
