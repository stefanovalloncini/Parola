import SwiftUI

/// Lays its subviews out on one centred row, wrapping to the next when the proposed width runs out.
struct CentredFlow: Layout {
    var spacing: CGFloat = DS.Spacing.small

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        FlowRows.size(of: rows(within: proposal.width ?? .infinity, of: subviews), spacing: spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(within: bounds.width, of: subviews) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(within limit: CGFloat, of subviews: Subviews) -> [FlowRows.Row] {
        FlowRows.rows(sizes: subviews.map { $0.sizeThatFits(.unspecified) }, limit: limit, spacing: spacing)
    }
}
