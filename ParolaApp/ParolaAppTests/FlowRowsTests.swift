import Foundation
import Testing
@testable import Parola

@Suite("Flow row wrapping")
struct FlowRowsTests {
    private let spacing: CGFloat = 8

    @Test("a row that fits stays one row")
    func oneRowWhenItFits() {
        let rows = FlowRows.rowIndices(widths: [160, 120, 200], limit: 631, spacing: spacing)
        #expect(rows == [[0, 1, 2]])
    }

    @Test("the pill that overruns moves to a second row")
    func wrapsToASecondRow() {
        let rows = FlowRows.rowIndices(widths: [200, 130, 330], limit: 631, spacing: spacing)
        #expect(rows == [[0, 1], [2]])
    }

    @Test("a subview wider than the limit gets a row of its own rather than vanishing")
    func oversizedSubviewKeepsItsRow() {
        let rows = FlowRows.rowIndices(widths: [700, 120], limit: 400, spacing: spacing)
        #expect(rows == [[0], [1]])
    }

    @Test("no subviews means no rows")
    func emptyStaysEmpty() {
        #expect(FlowRows.rowIndices(widths: [], limit: 400, spacing: spacing).isEmpty)
    }

    @Test("spacing counts against the limit")
    func spacingIsChargedBetweenSubviews() {
        #expect(FlowRows.rowIndices(widths: [200, 200], limit: 400, spacing: 0) == [[0, 1]])
        #expect(FlowRows.rowIndices(widths: [200, 200], limit: 400, spacing: spacing) == [[0], [1]])
    }

    @Test("a row is as wide as its subviews and as tall as the tallest")
    func rowsCarryTheirSize() {
        let sizes = [CGSize(width: 100, height: 20), CGSize(width: 50, height: 30), CGSize(width: 300, height: 20)]
        let rows = FlowRows.rows(sizes: sizes, limit: 200, spacing: spacing)
        #expect(rows.map(\.indices) == [[0, 1], [2]])
        #expect(rows[0].width == 158)
        #expect(rows[0].height == 30)
        #expect(rows[1].width == 300)
    }

    @Test("stacked rows are as tall as their rows plus the gaps between them")
    func stackedRowsAddTheGaps() {
        let sizes = Array(repeating: CGSize(width: 300, height: 20), count: 3)
        let size = FlowRows.size(of: FlowRows.rows(sizes: sizes, limit: 300, spacing: spacing), spacing: spacing)
        #expect(size.width == 300)
        #expect(size.height == 76)
    }
}
