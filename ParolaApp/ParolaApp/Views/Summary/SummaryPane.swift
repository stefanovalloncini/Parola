import SwiftUI
import ParolaCore

struct SummaryPane: View {
    @Environment(AppModel.self) private var model

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
        .axBranch("Summary")
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
            .axLeaf("Summary.Button.Regenerate")
        }
    }

    private func metadataStrip(summary: Summary) -> some View {
        let words = summary.text.split { $0.isWhitespace || $0.isNewline }.count
        let chars = summary.text.count
        let modelName = model.transcript?.modelName ?? ""

        return HStack(spacing: 6) {
            metaLabel(Text("\(words) words"))
            dot
            metaLabel(Text("\(chars) chars"))
            if !modelName.isEmpty {
                dot
                metaLabel(Text(verbatim: modelName))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
    }

    private var dot: some View {
        Text(verbatim: "·")
            .font(DS.Font.captionMono)
            .foregroundStyle(DS.Color.secondaryText.opacity(0.5))
    }

    private func metaLabel(_ text: Text) -> some View {
        text
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
