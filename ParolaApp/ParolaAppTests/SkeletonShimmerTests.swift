import AppKit
import SwiftUI
import Testing
@testable import Parola

@MainActor
@Suite("Skeleton shimmer", .serialized)
struct SkeletonShimmerTests {
    @Test("the band's leading edge runs from one and a half widths before the lines to as far past their start, evenly, again and again")
    func sweepRunsTheLines() {
        let sweep = Shimmer.sweep(width: 400, beginTime: 7)
        var start: [Float] = [0, 0], end: [Float] = [0, 0]
        sweep.timingFunction?.getControlPoint(at: 1, values: &start)
        sweep.timingFunction?.getControlPoint(at: 2, values: &end)
        #expect(sweep.keyPath == "transform.translation.x")
        #expect(sweep.fromValue as? CGFloat == -600)
        #expect(sweep.toValue as? CGFloat == 600)
        #expect(sweep.duration == 1.25)
        #expect(sweep.beginTime == 7)
        #expect(sweep.repeatCount == .infinity)
        #expect(start == [0, 0] && end == [1, 1], "a linear pace")
    }

    private func sweepViews(in view: NSView) -> [Shimmer.SweepView] {
        ((view as? Shimmer.SweepView).map { [$0] } ?? []) + view.subviews.flatMap(sweepViews(in:))
    }

    private func components(_ color: Any?) -> [CGFloat]? {
        guard let color, CFGetTypeID(color as CFTypeRef) == CGColor.typeID else { return nil }
        let srgb = (color as! CGColor).converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)
        return srgb?.components?.map { ($0 * 1000).rounded() / 1000 }
    }

    @Test("the lines shimmer on a layer the render server moves, half their width, fading to the highlight and out")
    func shimmerIsOnALayer() throws {
        for (scheme, ink) in [(ColorScheme.light, [CGFloat(0), 0, 0, 0.07]), (.dark, [1, 1, 1, 0.22])] {
            let hosted = HostedWindow(SkeletonLines(count: 6).frame(width: 400).environment(\.colorScheme, scheme), width: 400, height: 300)
            defer { hosted.close() }
            let view = try #require(sweepViews(in: hosted.host).first)
            #expect(view.band.frame.width == 200)
            #expect(view.band.frame.height == view.bounds.height && view.bounds.height > 100)
            #expect(view.band.animation(forKey: Shimmer.key) != nil)
            let colors = try #require(view.band.colors)
            #expect(colors.count == 3)
            #expect(components(colors[1]) == ink, "\(scheme)")
            #expect(components(colors[0]) == Array(ink.dropLast()) + [0], "the band fades out in the highlight's own colour")
            #expect(components(colors[2]) == components(colors[0]))
        }
    }

    @Test("under Reduce Motion the lines hold still, with no layer to move")
    func reduceMotionHoldsStill() {
        let hosted = HostedWindow(
            SkeletonLines(count: 6).frame(width: 400).environment(\._accessibilityReduceMotion, true), width: 400, height: 300
        )
        defer { hosted.close() }
        #expect(sweepViews(in: hosted.host).isEmpty)
    }
}
