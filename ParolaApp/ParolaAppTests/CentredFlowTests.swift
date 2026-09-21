import Foundation
import Testing
@testable import Parola

@Suite("Centred flow wrapping")
struct CentredFlowTests {
    private let spacing: CGFloat = 8

    @Test("a row that fits stays one row")
    func oneRowWhenItFits() {
        let rows = CentredFlow.rowIndices(widths: [160, 120, 200], limit: 631, spacing: spacing)
        #expect(rows == [[0, 1, 2]])
    }

    @Test("the pill that overruns moves to a second row")
    func wrapsToASecondRow() {
        let rows = CentredFlow.rowIndices(widths: [200, 130, 330], limit: 631, spacing: spacing)
        #expect(rows == [[0, 1], [2]])
    }

    @Test("a subview wider than the limit gets a row of its own rather than vanishing")
    func oversizedSubviewKeepsItsRow() {
        let rows = CentredFlow.rowIndices(widths: [700, 120], limit: 400, spacing: spacing)
        #expect(rows == [[0], [1]])
    }

    @Test("no subviews means no rows")
    func emptyStaysEmpty() {
        #expect(CentredFlow.rowIndices(widths: [], limit: 400, spacing: spacing).isEmpty)
    }

    @Test("spacing counts against the limit")
    func spacingIsChargedBetweenSubviews() {
        #expect(CentredFlow.rowIndices(widths: [200, 200], limit: 400, spacing: 0) == [[0, 1]])
        #expect(CentredFlow.rowIndices(widths: [200, 200], limit: 400, spacing: spacing) == [[0], [1]])
    }
}
