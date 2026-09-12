import SwiftUI
import ParolaCore

struct SummaryBody: View {
    let summary: Summary

    var body: some View {
        if Self.isEmpty(summary) {
            ContentUnavailableView(
                "No Summary",
                systemImage: "text.alignleft",
                description: Text("The model didn't return a summary.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.xlarge) {
                    if !summaryText.isEmpty {
                        Text(summaryText)
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
    }

    private var summaryText: String {
        summary.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isEmpty(_ summary: Summary) -> Bool {
        summary.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && summary.chapters.isEmpty
    }

    private var chaptersSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.regular) {
            Text("Chapters")
                .font(DS.Font.secondary.smallCaps())
                .foregroundStyle(DS.Color.secondaryText)
                .tracking(0.6)

            VStack(spacing: 0) {
                ForEach(Array(summary.chapters.enumerated()), id: \.element.id) { idx, chapter in
                    SummaryChapterRow(chapter: chapter)
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
