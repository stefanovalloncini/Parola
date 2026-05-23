import SwiftUI
import ParolaCore

struct RecommendedRow: View {
    let variant: ModelVariant
    let kind: ModelCardRow.Kind
    let onDownload: () -> Void

    var body: some View {
        ModelCardRow(
            variant: variant,
            kind: kind,
            primaryAction: onDownload
        )
    }
}
