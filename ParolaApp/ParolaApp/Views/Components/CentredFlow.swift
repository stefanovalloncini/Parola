import SwiftUI

/// Lays its subviews out on one centred row, wrapping to the next when the proposed width runs out.
struct CentredFlow: Layout {
    var spacing: CGFloat = DS.Spacing.small

    func makeCache(subviews: Subviews) -> FlowRows.Cache {
        FlowRows.Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    func updateCache(_ cache: inout FlowRows.Cache, subviews: Subviews) {
        cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout FlowRows.Cache) -> CGSize {
        FlowRows.size(of: rows(within: proposal.width ?? .infinity, of: cache), spacing: spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout FlowRows.Cache) {
        var y = bounds.minY
        for row in rows(within: bounds.width, of: cache) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for index in row.indices {
                let size = cache.sizes[index]
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(within limit: CGFloat, of cache: FlowRows.Cache) -> [FlowRows.Row] {
        FlowRows.rows(sizes: cache.sizes, limit: limit, spacing: spacing)
    }
}
