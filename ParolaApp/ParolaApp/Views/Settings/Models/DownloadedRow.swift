import SwiftUI
import ParolaCore

struct DownloadedRow: View {
    let variant: ModelVariant
    let isActive: Bool
    let actualSizeBytes: Int64?
    let isDeleting: Bool
    let onActivate: () -> Void
    let onRequestDelete: (() -> Void)?

    var body: some View {
        ModelCardRow(
            variant: variant,
            kind: isActive ? .active : .installed,
            actualSizeBytes: actualSizeBytes,
            isDeleting: isDeleting,
            primaryAction: onActivate,
            deleteAction: onRequestDelete
        )
    }
}

struct DownloadedEmpty: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray")
                .foregroundStyle(DS.Color.secondaryText)
            Text("No models on disk yet. Switch the filter to All to download one.")
                .foregroundStyle(DS.Color.secondaryText)
            Spacer()
        }
    }
}
