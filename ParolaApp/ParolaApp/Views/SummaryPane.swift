import SwiftUI
import ParolaCore

struct SummaryPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Spacing.tight) {
                header
                if let summary = model.transcript?.summary, !summary.text.isEmpty {
                    metadataStrip(summary: summary)
                }
            }
            .padding(.horizontal, DS.Spacing.medium)
            .padding(.vertical, DS.Spacing.regular)

            Divider().opacity(0.4)
            content
        }
        .background(DS.Color.surface)
    }

    private var header: some View {
        HStack {
            Text("Summary")
                .font(DS.Font.heading)
            Spacer()
            Button(action: regenerate) {
                if model.isSummarising {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.Color.secondaryText)
            .disabled(model.transcript == nil || model.isSummarising)
            .help(model.transcript?.summary == nil ? "Generate summary" : "Regenerate summary")
        }
    }

    private func metadataStrip(summary: Summary) -> some View {
        let words = summary.text.split { $0.isWhitespace || $0.isNewline }.count
        let chars = summary.text.count
        let modelName = model.transcript?.modelName ?? ""

        return HStack(spacing: 6) {
            metaLabel("\(words) words")
            dot
            metaLabel("\(chars) chars")
            if !modelName.isEmpty {
                dot
                metaLabel(modelName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
    }

    private var dot: some View {
        Text("·")
            .font(DS.Font.captionMono)
            .foregroundStyle(DS.Color.secondaryText.opacity(0.5))
    }

    private func metaLabel(_ text: String) -> some View {
        Text(text)
            .font(DS.Font.captionMono)
            .foregroundStyle(DS.Color.secondaryText)
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.summaryError {
            SummaryError(message: error)
        } else if let summary = model.transcript?.summary {
            SummaryBody(summary: summary)
        } else if model.transcript == nil {
            ContentUnavailableView(
                "No transcript",
                systemImage: "doc.text",
                description: Text("Open a transcript to generate a summary.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            SummaryEmpty(isWorking: model.isSummarising) {
                model.summariseTranscript()
            }
        }
    }

    private func regenerate() {
        model.summariseTranscript()
    }
}

private struct SummaryBody: View {
    let summary: Summary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.xlarge) {
                if !summary.text.isEmpty {
                    Text(summary.text)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.primaryText)
                        .lineSpacing(4)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }

                if !summary.chapters.isEmpty {
                    chaptersSection
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, DS.Spacing.large)
            .padding(.vertical, DS.Spacing.large)
        }
    }

    private var chaptersSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.regular) {
            Text("Chapters")
                .font(DS.Font.caption.smallCaps())
                .foregroundStyle(DS.Color.secondaryText)
                .tracking(0.6)

            VStack(spacing: 0) {
                ForEach(Array(summary.chapters.enumerated()), id: \.element.id) { idx, chapter in
                    ChapterRow(chapter: chapter)
                    if idx < summary.chapters.count - 1 {
                        Divider().opacity(0.4)
                    }
                }
            }
            .background(DS.Color.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous))
        }
    }
}

private struct ChapterRow: View {
    let chapter: Chapter
    @EnvironmentObject var model: AppModel
    @State private var hovering = false

    var body: some View {
        Button {
            model.seekTo(chapter: chapter)
        } label: {
            HStack(spacing: DS.Spacing.regular) {
                Text(timestamp(chapter.start))
                    .font(DS.Font.captionMono)
                    .foregroundStyle(DS.Color.secondaryText)
                    .frame(width: 64, alignment: .leading)
                Text(chapter.title)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.primaryText)
                Spacer()
                Image(systemName: "play.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.Color.accent)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, DS.Spacing.regular)
            .padding(.vertical, DS.Spacing.small)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hovering ? DS.Color.accent.opacity(0.06) : Color.clear)
        .onHover { hovering = $0 }
    }

    private func timestamp(_ s: Double) -> String {
        Duration.seconds(s).formatted(
            .time(pattern: s >= 3600 ? .hourMinuteSecond : .minuteSecond)
        )
    }
}

private struct SummaryEmpty: View {
    let isWorking: Bool
    let onGenerate: () -> Void

    var body: some View {
        VStack(spacing: DS.Spacing.medium) {
            Image(systemName: "sparkles")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(DS.Color.accent)
                .opacity(isWorking ? 0.4 : 1)

            Text(isWorking ? "Generating summary…" : "No summary yet")
                .font(DS.Font.heading)
                .foregroundStyle(DS.Color.primaryText)

            if !isWorking {
                Text("Generate a short overview with chapter markers you can jump to.")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .lineSpacing(2)
            } else {
                ProgressView()
                    .controlSize(.small)
            }

            if !isWorking {
                Button(action: onGenerate) {
                    Text("Generate")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, DS.Spacing.large)
                        .padding(.vertical, 8)
                        .background(
                            Capsule(style: .continuous)
                                .fill(DS.Color.accent)
                        )
                }
                .buttonStyle(.plain)
                .padding(.top, DS.Spacing.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Spacing.large)
    }
}

private struct SummaryError: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            Label("Couldn't generate a summary", systemImage: "exclamationmark.triangle")
                .font(DS.Font.heading)
                .foregroundStyle(DS.Color.danger)
            Text(message)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryText)
        }
        .padding(DS.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
