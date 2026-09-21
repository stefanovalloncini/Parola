import Foundation
import SwiftUI
import Testing
@testable import Parola

@Suite("Introduction stage")
struct IntroductionStageTests {
    @Test("the warm point drifts gently and stays inside the stage")
    func warmPointStaysInside() {
        for second in stride(from: 0.0, through: 180.0, by: 2.5) {
            let point = IntroductionStage.warmPoint(seconds: second)
            #expect(abs(point.x - 0.32) <= 0.08)
            #expect(abs(point.y - 0.28) <= 0.08)
            #expect(point.x > 0.08 && point.x < 0.92)
            #expect(point.y > 0.08 && point.y < 0.92)
        }
    }

    @Test("each axis takes half a minute to swing and back")
    func driftIsSlow() {
        let rest = IntroductionStage.warmPoint(seconds: 0)
        #expect(abs(rest.x - 0.32) < 0.0001)
        #expect(abs(rest.y - 0.28) < 0.0001)
        // A quarter period in, each axis stands at its extreme: x at 31/4 s, y at 27/4 s.
        #expect(abs(IntroductionStage.warmPoint(seconds: 7.75).x - 0.38) < 0.001)
        #expect(abs(IntroductionStage.warmPoint(seconds: 6.75).y - 0.33) < 0.001)
        #expect(abs(IntroductionStage.warmPoint(seconds: 23.25).x - 0.26) < 0.001)
        #expect(abs(IntroductionStage.warmPoint(seconds: 20.25).y - 0.23) < 0.001)
    }

    @Test("the eight boundary points never leave their edges")
    func boundaryPointsStayPut() {
        let fixed: [Int: SIMD2<Float>] = [
            0: [0, 0], 1: [0.5, 0], 2: [1, 0],
            3: [0, 0.5], 5: [1, 0.5],
            6: [0, 1], 7: [0.5, 1], 8: [1, 1]
        ]
        for second in [0.0, 3.5, 7.75, 16.0, 31.0, 64.5, 300.0] {
            let points = IntroductionStage.points(seconds: second)
            #expect(points.count == 9)
            for (index, expected) in fixed {
                #expect(points[index] == expected, "point \(index) at \(second)s")
            }
            #expect(points[4] == IntroductionStage.warmPoint(seconds: second))
        }
    }

    @MainActor
    @Test("only the interior point and the far corner carry the accent")
    func coloursAreCanvasExceptTheAccentPoints() {
        let colours = IntroductionStage.colors()
        let canvas = DS.Palette.canvas
        #expect(colours.count == 9)
        for index in [0, 1, 2, 3, 5, 6, 7] {
            #expect(colours[index] == canvas, "point \(index)")
        }
        #expect(colours[4] == DS.Color.accent.opacity(0.16))
        #expect(colours[8] == DS.Color.accent.opacity(0.07))
        #expect(colours[4] != canvas)
        #expect(colours[8] != canvas)
    }
}
