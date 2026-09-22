import SwiftUI
import ParolaCore

/// The window's reading column, in whichever display mode the app is set to.
struct EntryViewerTranscript: View {
    let session: EntryWindowSession
    let onEditAttempt: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.transcriptDisplayMode {
        case .segments:
            EntryViewerSegments(session: session, onEditAttempt: onEditAttempt)
        case .transcript:
            EntryViewerContinuous(session: session, onEditAttempt: onEditAttempt)
        }
    }
}

struct EntryViewerSegments: View {
    let session: EntryWindowSession
    let onEditAttempt: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Spacing.small) {
                    ForEach(session.visibleSegments) { segment in
                        EntryViewerSegmentRow(
                            segment: segment,
                            isCurrent: session.currentSegmentID == segment.id,
                            isFavorite: session.isFavorite(segment.id),
                            speakerColorIndex: segment.speaker.flatMap { session.speakerColorIndices[$0] },
                            translation: session.translations[segment.id],
                            sideBySide: model.translationSideBySide,
                            matches: session.matches(in: segment.id),
                            currentMatchID: session.currentMatch?.id,
                            monospacedTimestamps: model.monospacedTimestamps,
                            onSeek: { session.seek(toSegment: segment.id) },
                            onEditAttempt: onEditAttempt
                        )
                        .id(segment.id)
                    }
                }
                .padding(.horizontal, DS.Spacing.large)
                .padding(.vertical, DS.Spacing.regular)
            }
            .onChange(of: session.currentSegmentID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

}

private struct EntryViewerSegmentRow: View {
    let segment: TranscriptSegment
    let isCurrent: Bool
    let isFavorite: Bool
    let speakerColorIndex: Int?
    let translation: String?
    let sideBySide: Bool
    let matches: [TranscriptMatch]
    let currentMatchID: TranscriptMatch.ID?
    let monospacedTimestamps: Bool
    let onSeek: () -> Void
    let onEditAttempt: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            speakerLine
            contentRow
        }
        .padding(.horizontal, DS.Spacing.regular)
        .padding(.vertical, DS.Spacing.regular)
        .background(isCurrent ? DS.Color.highlight.opacity(0.10) : DS.Color.surfaceElevated)
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.regular)
                .stroke(
                    isCurrent ? DS.Color.highlight.opacity(0.55) : DS.Color.separator.opacity(0.6),
                    lineWidth: isCurrent ? 1.5 : 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.regular))
        .contentShape(Rectangle())
        // simultaneousGesture: .textSelection consumes plain taps, so a row-level .onTapGesture never fires on text.
        .simultaneousGesture(TapGesture(count: 2).onEnded { onEditAttempt() })
        .simultaneousGesture(TapGesture().onEnded { onSeek() })
    }

    private var speakerLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.small) {
            if let raw = segment.speaker, let label = SegmentCard.speakerLabel(for: raw) {
                Text(verbatim: label)
                    .font(DS.Font.bodyStrong)
                    .foregroundStyle(DS.speakerColor(for: raw, colorIndex: speakerColorIndex))
            }
            Spacer(minLength: DS.Spacing.small)
            if isFavorite {
                Image(systemName: "star.fill")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.accent)
                    .accessibilityLabel("Favorite")
                    .axLeaf("Badge.Favorite")
            }
            Text(verbatim: Timecode.format(segment.start))
                .font(monospacedTimestamps ? DS.Font.mono : DS.Font.secondary)
                .foregroundStyle(isCurrent ? DS.Color.highlight : DS.Color.secondaryText)
        }
    }

    @ViewBuilder
    private var contentRow: some View {
        if let translation, sideBySide {
            HStack(alignment: .top, spacing: DS.Spacing.regular) {
                text.frame(maxWidth: .infinity, alignment: .leading)
                translationText(translation).frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: DS.Spacing.tight) {
                text.frame(maxWidth: .infinity, alignment: .leading)
                if let translation {
                    translationText(translation).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var text: some View {
        Text(TranscriptSearchHighlight.attributed(
            segment.text,
            matches: matches,
            currentMatchID: currentMatchID
        ))
        .font(DS.Font.transcript)
        .textSelection(.enabled)
    }

    private func translationText(_ value: String) -> some View {
        Text(verbatim: value.trimmingCharacters(in: .whitespacesAndNewlines))
            .font(DS.Font.transcript)
            .foregroundStyle(DS.Color.secondaryText)
            .textSelection(.enabled)
            .axLeaf("Text.Translation")
    }
}
