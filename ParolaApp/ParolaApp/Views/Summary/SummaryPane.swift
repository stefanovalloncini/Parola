import SwiftUI
import ParolaCore

struct SummaryPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            mainColumn
            Divider()
            SummaryOptionsColumn(options: $model.summaryOptions, autostart: $model.autostartSummary)
                .frame(width: 260)
        }
        .background(DS.Color.surface)
        .task { model.refreshAIAvailability() }
        .axBranch("Summary")
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Spacing.tight) {
                header
                if let summary = model.transcript?.summary,
                   !summary.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    metadataStrip(summary: summary)
                }
            }
            .padding(.horizontal, DS.Spacing.medium)
            .padding(.vertical, DS.Spacing.regular)

            Divider().opacity(0.4)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        Text("Summary")
            .font(DS.Font.heading)
    }

    private func metadataStrip(summary: Summary) -> some View {
        let words = summary.text.split { $0.isWhitespace || $0.isNewline }.count
        let chars = summary.text.count
        let provider = summary.provider

        return HStack(spacing: 6) {
            metaLabel(Text("\(words) words"))
            dot
            metaLabel(Text("\(chars) chars"))
            if !provider.isEmpty {
                dot
                metaLabel(Text(verbatim: provider))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
    }

    private var dot: some View {
        Text(verbatim: "·")
            .font(DS.Font.mono)
            .foregroundStyle(DS.Color.secondaryText.opacity(0.5))
    }

    private func metaLabel(_ text: Text) -> some View {
        text
            .font(DS.Font.mono)
            .foregroundStyle(DS.Color.secondaryText)
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.summaryError {
            SummaryError(message: error) { model.summariseTranscript() }
        } else if let summary = model.transcript?.summary {
            SummaryBody(summary: summary)
        } else if model.transcript == nil {
            ContentUnavailableView(
                "No Transcript",
                systemImage: "doc.text",
                description: Text("Open a transcript to generate a summary.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !model.isAIAvailable(for: .summary), let reason = model.aiUnavailableReason {
            ContentUnavailableView {
                Label("Summaries Need Apple Intelligence", systemImage: "sparkles")
            } description: {
                Text(verbatim: reason)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            SummaryEmpty(
                isWorking: model.isSummarising,
                onGenerate: { model.summariseTranscript() },
                onStop: { model.stopAIRun(.summary) }
            )
        }
    }
}
