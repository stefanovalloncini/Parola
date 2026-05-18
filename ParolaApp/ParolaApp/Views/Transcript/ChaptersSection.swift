import SwiftUI
import ParolaCore

struct ChaptersSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        InfoSection(titleVerbatim: titleLabel) {
            if model.isExtractingChapters {
                progressRow
            } else if model.smartChapters.isEmpty {
                emptyRow
            } else {
                ForEach(model.smartChapters) { chapter in
                    ChapterRow(chapter: chapter) { model.seekTo(chapter: chapter) }
                }
                actionsRow
            }
        }
    }

    private var titleLabel: String {
        if model.smartChapters.isEmpty { return String(localized: "Chapters") }
        return String(localized: "Chapters · \(model.smartChapters.count)")
    }

    private var progressRow: some View {
        HStack(spacing: DS.Spacing.small) {
            ProgressView().controlSize(.small)
            Text("Generating chapters…")
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.secondaryText)
        }
    }

    private var emptyRow: some View {
        Button("Generate chapters") { model.extractSmartChapters() }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("transcript.inspector.chapters")
    }

    private var actionsRow: some View {
        HStack(spacing: DS.Spacing.small) {
            Button("Regenerate") { model.extractSmartChapters() }
                .controlSize(.small)
            Spacer()
            Button("Clear") { model.clearSmartChapters() }
                .controlSize(.small)
        }
    }
}

private struct ChapterRow: View {
    let chapter: Chapter
    let onJump: () -> Void

    var body: some View {
        Button(action: onJump) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.small) {
                Text(Timecode.format(chapter.start))
                    .font(DS.Font.caption.monospacedDigit())
                    .foregroundStyle(DS.Color.accent)
                Text(chapter.title)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.primaryText)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Jump to \(Timecode.format(chapter.start))")
    }
}
