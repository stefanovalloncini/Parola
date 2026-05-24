import SwiftUI

struct SummaryEmpty: View {
    let isWorking: Bool
    let onGenerate: () -> Void

    var body: some View {
        VStack(spacing: DS.Spacing.medium) {
            Image(systemName: "sparkles")
                .font(.system(size: 32, weight: .light))
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
                .axLeaf("Summary.Button.Generate")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Spacing.large)
    }
}
