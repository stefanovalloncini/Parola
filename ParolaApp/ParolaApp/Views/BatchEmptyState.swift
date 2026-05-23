import SwiftUI

struct BatchEmptyState: View {
    @Environment(AppModel.self) private var model
    let isDropping: Bool

    var body: some View {
        VStack(spacing: DS.Spacing.medium) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(DS.Color.secondaryText.opacity(0.55))
                .padding(.bottom, DS.Spacing.small)

            Text("Batch Mode.")
                .font(.system(.largeTitle, design: .default, weight: .bold))
                .foregroundStyle(DS.Color.primaryText)

            Text("Transcribe and export multiple files at once.\nSelect files to transcribe or drag them onto the app to continue.")
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                model.presentBatchOpenPanel()
            } label: {
                Text("Open Files")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, DS.Spacing.large)
                    .padding(.vertical, DS.Spacing.small)
            }
            .buttonStyle(.borderedProminent)
            .tint(DS.Color.accent)
            .controlSize(.large)
            .padding(.top, DS.Spacing.small)
            .accessibilityIdentifier("batch.openFiles")
        }
        .frame(maxWidth: 460)
        .padding(DS.Spacing.large)
        .opacity(isDropping ? 0.4 : 1)
    }
}
