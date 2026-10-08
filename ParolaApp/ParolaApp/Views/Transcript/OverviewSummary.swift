import SwiftUI
import ParolaCore

/// The summary's first lines and the way to the rest, or the one button that writes it.
struct OverviewSummary: View {
    @Environment(AppModel.self) private var model

    static let excerptLines = 4

    private var summaryText: String? {
        guard let text = model.transcript?.summary?.text.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    var body: some View {
        OverviewSection(title: Text("Summary")) {
            if model.isSummarising {
                OverviewProgressRow(text: "Generating summary…", leaf: "Overview.Button.StopSummary") {
                    model.stopAIRun(.summary)
                }
            } else if let summaryText {
                excerpt(summaryText)
            } else if let error = model.summaryError {
                AIStatusNote(message: error, kind: .failure)
                Button("Retry") { model.summariseTranscript() }
                    .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                    .axLeaf("Overview.Button.RetrySummary")
            } else if !model.isAIAvailable(for: .summary), let reason = model.aiUnavailableReason {
                AIStatusNote(message: reason)
            } else {
                Text("Choose Summarize to get a short overview with chapter markers you can jump to.")
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Summarize") { model.summariseTranscript() }
                    .buttonStyle(DSPillButtonStyle(kind: .secondary, size: .compact))
                    .axLeaf("Overview.Button.Summarize")
            }
        }
    }

    @ViewBuilder
    private func excerpt(_ text: String) -> some View {
        Text(text)
            .font(DS.Font.body)
            .foregroundStyle(DS.Color.primaryText)
            .lineSpacing(2)
            .lineLimit(Self.excerptLines)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        if model.canShow(.summary) {
            Button { model.setTranscriptPaneMode(.summary) } label: {
                HStack(spacing: DS.Spacing.hair) {
                    Text("Show Summary")
                    Image(systemName: "chevron.right")
                        .font(DS.Font.caption)
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.plain)
            .font(DS.Font.secondary)
            .foregroundStyle(DS.Color.accentInk)
            .accessibilityLabel(Text("Show Summary"))
            .axLeaf("Overview.Button.ShowSummary")
        }
    }
}
