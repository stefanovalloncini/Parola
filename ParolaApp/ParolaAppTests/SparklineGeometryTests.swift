import CoreGraphics
import Foundation
import Testing
@testable import Parola

@Suite("SparklineGeometry")
struct SparklineGeometryTests {
    private let height: CGFloat = 44
    private let lineWidth: CGFloat = 2

    @Test("peak value sits half a stroke below the top edge, not at it")
    func peakInsetFromTop() {
        let y = SparklineGeometry.y(value: 50, maxValue: 50, height: height, lineWidth: lineWidth)
        #expect(y == lineWidth / 2)
    }

    @Test("zero value sits half a stroke above the bottom edge, not at it")
    func zeroInsetFromBottom() {
        let y = SparklineGeometry.y(value: 0, maxValue: 50, height: height, lineWidth: lineWidth)
        #expect(y == height - lineWidth / 2)
    }

    @Test("midpoint value maps to the vertical center")
    func midpointAtCenter() {
        let y = SparklineGeometry.y(value: 25, maxValue: 50, height: height, lineWidth: lineWidth)
        #expect(y == height / 2)
    }

    @Test("the full stroke stays inside the frame for both extremes")
    func strokeNeverClips() {
        let peak = SparklineGeometry.y(value: 50, maxValue: 50, height: height, lineWidth: lineWidth)
        let zero = SparklineGeometry.y(value: 0, maxValue: 50, height: height, lineWidth: lineWidth)
        #expect(peak - lineWidth / 2 >= 0)
        #expect(zero + lineWidth / 2 <= height)
    }

    @Test("a zero maximum stays finite and pins to the baseline")
    func zeroMaximumDoesNotDivide() {
        let y = SparklineGeometry.y(value: 0, maxValue: 0, height: height, lineWidth: lineWidth)
        #expect(y.isFinite)
        #expect(y == height - lineWidth / 2)
    }
}
