import SwiftUI

struct ProgressPane: View {
    let title: String
    let progress: Double?
    var body: some View {
        VStack(spacing: DS.Spacing.regular) {
            Text(title)
                .font(DS.Font.heading)
                .foregroundStyle(DS.Color.primaryText)
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(DS.Color.accent)
                    .frame(width: 280)
                Text("\(Int(progress * 100))%")
                    .font(DS.Font.captionMono)
                    .foregroundStyle(DS.Color.secondaryText)
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(DS.Color.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
