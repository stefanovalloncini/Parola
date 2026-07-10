import SwiftUI
import ParolaCore

struct RecommendedRow: View {
    let variant: ModelVariant
    let kind: ModelCardRow.Kind
    var downloadDisabled: Bool = false
    let onDownload: () -> Void
    var onCancelDownload: (() -> Void)? = nil

    var body: some View {
        ModelCardRow(
            variant: variant,
            kind: kind,
            downloadDisabled: downloadDisabled,
            primaryAction: onDownload,
            cancelAction: onCancelDownload
        )
    }
}
