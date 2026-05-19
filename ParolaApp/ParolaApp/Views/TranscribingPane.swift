import SwiftUI

struct TranscribingPane: View {
    let file: URL
    let partial: String

    var body: some View {
        VStack(spacing: DS.Spacing.regular) {
            HStack(spacing: DS.Spacing.small) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(DS.Color.accent)
                Text("Transcribing \(file.lastPathComponent)…")
                    .font(DS.Font.heading)
                    .foregroundStyle(DS.Color.primaryText)
            }

            if partial.isEmpty {
                Spacer()
            } else {
                ScrollView {
                    Text(partial)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Spacing.regular)
                        .textSelection(.enabled)
                }
                .background(DS.Color.surface)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.regular))
            }
        }
        .padding(DS.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
