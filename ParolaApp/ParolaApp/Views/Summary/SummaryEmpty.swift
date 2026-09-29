import SwiftUI

struct SummaryEmpty: View {
    let isWorking: Bool
    let onGenerate: () -> Void
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 32

    var body: some View {
        VStack(spacing: DS.Spacing.medium) {
            Image(systemName: "sparkles")
                .font(.system(size: iconSize, weight: .light))
                .foregroundStyle(DS.Color.accent)
                .opacity(isWorking ? 0.4 : 1)

            Group {
                if isWorking {
                    Text("Generating summary…")
                } else {
                    Text("No summary yet")
                }
            }
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
                Button("Generate", action: onGenerate)
                    .buttonStyle(DSPillButtonStyle(kind: .primary))
                    .padding(.top, DS.Spacing.small)
                    .axLeaf("Summary.Button.Generate")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Spacing.large)
    }
}
