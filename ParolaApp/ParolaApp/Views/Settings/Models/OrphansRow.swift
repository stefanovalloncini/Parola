import SwiftUI
import ParolaCore

struct OrphansRow: View {
    let entry: ModelInfo
    let displaySize: Int64?
    let isDeleting: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.full")
                .foregroundStyle(DS.Color.secondaryText)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(DS.Font.bodyStrong)
                if let bytes = displaySize {
                    Text(AppFormat.byteSize(bytes))
                        .font(DS.Font.secondary)
                        .foregroundStyle(DS.Color.secondaryText)
                }
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
                .accessibilityLabel("Delete \(entry.name)")
                .accessibilityIdentifier("orphan.\(entry.name).delete")
            }
        }
    }
}
