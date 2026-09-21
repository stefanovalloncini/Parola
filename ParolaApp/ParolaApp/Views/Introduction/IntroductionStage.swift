import SwiftUI

/// The backdrop the whole introduction sits on: canvas with the accent warming the top-leading
/// third and the far corner, the warm point drifting slowly so the window isn't dead flat.
struct IntroductionStage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let rest = SIMD2<Float>(0.32, 0.28)
    private static let amplitude = SIMD2<Float>(0.06, 0.05)
    private static let periods = SIMD2<Double>(31, 27)

    var body: some View {
        let colors = Self.colors()
        return ZStack {
            DS.Palette.canvas
            if reduceMotion {
                mesh(warm: Self.rest, colors: colors)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    mesh(
                        warm: Self.warmPoint(seconds: context.date.timeIntervalSinceReferenceDate),
                        colors: colors
                    )
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    static func warmPoint(seconds: TimeInterval) -> SIMD2<Float> {
        SIMD2(
            rest.x + amplitude.x * Float(sin(seconds * 2 * .pi / periods.x)),
            rest.y + amplitude.y * Float(sin(seconds * 2 * .pi / periods.y))
        )
    }

    private static func colors() -> [Color] {
        let canvas = DS.Palette.canvas
        return [
            canvas, canvas, canvas,
            canvas, DS.Color.accent.opacity(0.16), canvas,
            canvas, canvas, DS.Color.accent.opacity(0.07)
        ]
    }

    private func mesh(warm: SIMD2<Float>, colors: [Color]) -> some View {
        MeshGradient(
            width: 3,
            height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], warm, [1, 0.5],
                [0, 1], [0.5, 1], [1, 1]
            ],
            colors: colors
        )
    }
}
