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
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(DS.Font.subheadline)
                if let bytes = displaySize {
                    Text(AppFormat.byteSize(bytes))
                        .font(DS.Font.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isDeleting {
                ProgressView().controlSize(.small)
                Text("Deleting…")
                    .font(DS.Font.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Delete this folder from disk")
                .accessibilityLabel("Delete \(entry.name)")
                .accessibilityIdentifier("orphan.\(entry.name).delete")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(DS.Color.surfaceElevated, in: RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous))
    }
}
