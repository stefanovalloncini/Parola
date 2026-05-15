import SwiftUI
import ParolaCore

struct SummaryPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.medium) {
            header

            if let summary = model.transcript?.summary {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Spacing.large) {
                        if !summary.text.isEmpty {
                            Text(summary.text)
                                .font(DS.Font.body)
                                .foregroundStyle(DS.Color.primaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if !summary.chapters.isEmpty {
                            VStack(alignment: .leading, spacing: DS.Spacing.small) {
                                Text("Chapters")
                                    .font(DS.Font.heading)
                                    .foregroundStyle(DS.Color.secondaryText)
                                ForEach(summary.chapters) { chapter in
                                    ChapterRow(chapter: chapter)
                                }
                            }
                        }
                    }
                    .padding(DS.Spacing.large)
                }
            } else if let error = model.summaryError {
                ErrorBox(message: error)
                    .padding(DS.Spacing.large)
            } else {
                EmptyState(isWorking: model.isSummarising)
                    .padding(DS.Spacing.large)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Summary")
                .font(DS.Font.heading)
            Spacer()
            Button {
                model.summariseTranscript()
            } label: {
                if model.isSummarising {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Summarise", systemImage: "sparkles")
                }
            }
            .disabled(model.transcript == nil || model.isSummarising)
        }
        .padding(.horizontal, DS.Spacing.large)
        .padding(.top, DS.Spacing.regular)
    }
}

private struct ChapterRow: View {
    let chapter: Chapter
    @EnvironmentObject var model: AppModel

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
            }
            .padding(.vertical, DS.Spacing.tight)
        }
        .buttonStyle(.plain)
    }

    private func timestamp(_ s: Double) -> String {
        Duration.seconds(s).formatted(
            .time(pattern: s >= 3600 ? .hourMinuteSecond : .minuteSecond)
        )
    }
}

private struct EmptyState: View {
    let isWorking: Bool
    var body: some View {
        VStack(spacing: DS.Spacing.regular) {
            Image(systemName: "sparkles")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(DS.Color.secondaryText)
            Text(isWorking ? "Working…" : "No summary yet")
                .font(DS.Font.heading)
            if !isWorking {
                Text("Click Summarise for a short overview and chapter markers you can jump to.")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ErrorBox: View {
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
    }
}
