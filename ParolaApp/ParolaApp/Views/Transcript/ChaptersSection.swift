import SwiftUI
import ParolaCore

struct ChaptersSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        InspectorSection(titleVerbatim: titleLabel) {
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
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            Button("Generate Chapters") { model.extractSmartChapters() }
                .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                .disabled(!model.isAIAvailable(for: .summary))
                .accessibilityIdentifier("transcript.inspector.chapters")
                .axLeaf("Chapters.Button.Generate")
            statusNote
        }
    }

    @ViewBuilder
    private var statusNote: some View {
        if !model.isAIAvailable(for: .summary), let reason = model.aiUnavailableReason {
            AIStatusNote(message: reason)
        } else if let error = model.chaptersError {
            AIStatusNote(message: error, kind: .failure)
        }
    }

    private var actionsRow: some View {
        HStack(spacing: DS.Spacing.small) {
            Button("Regenerate") { model.extractSmartChapters() }
                .controlSize(.small)
                .disabled(!model.isAIAvailable(for: .summary))
                .axLeaf("Chapters.Button.Regenerate")
            Spacer()
            Button("Clear") { model.clearSmartChapters() }
                .controlSize(.small)
                .axLeaf("Chapters.Button.Clear")
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
                    .font(DS.Font.mono)
                    .foregroundStyle(DS.Color.accentText)
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
        .axLeaf("Chapters.Button.Jump")
    }
}
