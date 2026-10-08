import SwiftUI

struct EarlierDownloadRow: View {
    let copy: SupersededCopy
    let isDeleting: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(DS.Color.secondaryText)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: copy.displayName)
                    .font(DS.Font.bodyStrong)
                    .axLeaf("Models.Row.EarlierDownload.\(copy.variantID)")
                caption
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
            }
            Spacer()
            if isDeleting {
                ProgressView().controlSize(.small)
                Text("Deleting…")
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Color.secondaryText)
            } else {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(GlyphButtonStyle())
                .foregroundStyle(DS.Color.secondaryText)
                .help("Delete this folder from disk")
                .accessibilityLabel("Delete \(copy.displayName)")
                .accessibilityHint(caption)
                .axLeaf("Models.Button.DeleteEarlierDownload.\(copy.variantID)")
            }
        }
    }

    private var caption: Text {
        Text("Earlier download · \(AppFormat.byteSize(copy.bytes))")
    }
}
