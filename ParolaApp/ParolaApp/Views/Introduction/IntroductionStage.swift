import SwiftUI

/// The backdrop the whole introduction sits on: canvas with the accent warming the top-leading
/// third and the far corner, the warm point drifting slowly so the window isn't dead flat.
struct IntroductionStage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated private static let rest = SIMD2<Float>(0.32, 0.28)
    nonisolated private static let amplitude = SIMD2<Float>(0.06, 0.05)
    nonisolated private static let periods = SIMD2<Double>(31, 27)

    var body: some View {
        let colors = Self.colors()
        return ZStack {
            DS.Palette.canvas
            if reduceMotion {
                // Both sines cross their rest position at zero.
                mesh(points: Self.points(seconds: 0), colors: colors)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 5.0)) { context in
                    mesh(
                        points: Self.points(seconds: context.date.timeIntervalSinceReferenceDate),
                        colors: colors
                    )
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    nonisolated static func warmPoint(seconds: TimeInterval) -> SIMD2<Float> {
        SIMD2(
            rest.x + amplitude.x * Float(sin(seconds * 2 * .pi / periods.x)),
            rest.y + amplitude.y * Float(sin(seconds * 2 * .pi / periods.y))
        )
    }

    /// The mesh's nine control points, row by row: eight on their own edge or corner, the warm one adrift.
    nonisolated static func points(seconds: TimeInterval) -> [SIMD2<Float>] {
        let warm = warmPoint(seconds: seconds)
        return [
            [0, 0], [0.5, 0], [1, 0],
            [0, 0.5], warm, [1, 0.5],
            [0, 1], [0.5, 1], [1, 1]
        ]
    }

    static func colors() -> [Color] {
        let canvas = DS.Palette.canvas
        return [
            canvas, canvas, canvas,
            canvas, DS.Color.accent.opacity(0.16), canvas,
            canvas, canvas, DS.Color.accent.opacity(0.07)
        ]
    }

    private func mesh(points: [SIMD2<Float>], colors: [Color]) -> some View {
        MeshGradient(width: 3, height: 3, points: points, colors: colors)
    }
}
