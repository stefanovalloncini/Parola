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
                    .truncationMode(.tail)
                    .help(Text(verbatim: session.title))
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(DS.Font.secondary)
                        .foregroundStyle(DS.Color.secondaryText)
                        .lineLimit(1)
                }
            }

            LanguagePill(language: session.transcript?.language)
                .help(Text(verbatim: LanguageDisplay.name(for: session.transcript?.language) ?? ""))
                .axLeaf("Label.Language")

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

            Button("Copy Transcript") { Task { await session.copyTranscript() } }
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
}

/// The transcript's language as the viewer shows it: its code in a pill, its name for VoiceOver.
struct LanguagePill: View {
    let language: String?

    var body: some View {
        if let code = LanguageDisplay.code(for: language) {
            Text(verbatim: code)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.accentInk)
                .padding(.horizontal, DS.Spacing.snug)
                .padding(.vertical, DS.Spacing.hair)
                .background(Capsule().fill(DS.Color.accentWash))
                .accessibilityLabel(Text(verbatim: LanguageDisplay.name(for: language) ?? code))
        }
    }
}
