import SwiftUI

/// The wrapping rule the flow layouts share: which subviews sit on a row, and how big the stack of rows is.
enum FlowRows {
    struct Row {
        let indices: [Int]
        let width: CGFloat
        let height: CGFloat
    }

    /// Which subviews share each row. Pure, so the wrapping rule can be checked without a host.
    static func rowIndices(widths: [CGFloat], limit: CGFloat, spacing: CGFloat) -> [[Int]] {
        var rows: [[Int]] = []
        var current: [Int] = []
        var used: CGFloat = 0
        for (index, width) in widths.enumerated() {
            if !current.isEmpty, used + spacing + width > limit {
                rows.append(current)
                current = []
                used = 0
            }
            used = current.isEmpty ? width : used + spacing + width
            current.append(index)
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    static func rows(sizes: [CGSize], limit: CGFloat, spacing: CGFloat) -> [Row] {
        rowIndices(widths: sizes.map(\.width), limit: limit, spacing: spacing).map { indices in
            Row(
                indices: indices,
                width: indices.reduce(0) { $0 + sizes[$1].width } + spacing * CGFloat(indices.count - 1),
                height: indices.map { sizes[$0].height }.max() ?? 0
            )
        }
    }

    static func size(of rows: [Row], spacing: CGFloat) -> CGSize {
        CGSize(
            width: rows.map(\.width).max() ?? 0,
            height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        )
    }
}
