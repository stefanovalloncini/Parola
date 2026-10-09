import AppKit
import SwiftUI
import Testing
@testable import Parola

@MainActor
@Suite("DS progress bar fill")
struct DSProgressBarTests {

    @Test("fill defaults to the accent color")
    func defaultsToAccent() {
        let bar = DSProgressBar(value: 0.5)
        #expect(bar.fill == nil)
        #expect(bar.resolvedFill == DS.Color.accent)
    }

    @Test("an explicit fill overrides the accent default")
    func explicitFillWins() {
        let bar = DSProgressBar(value: 0.5, fill: DS.Color.danger)
        #expect(bar.resolvedFill == DS.Color.danger)
    }

    @Test("a bar is as thick as the design system says unless a caller asks for thinner")
    func heightDefaultsToTheToken() {
        #expect(DSProgressBar(value: 0.5).height == DS.Size.progressBarHeight)
        #expect(DSProgressBar(value: 0.5, height: RecentlyDeletedRow.expiryBarHeight).height == 3)
        #expect(RecentlyDeletedRow.expiryBarHeight < DS.Size.progressBarHeight)
    }
}

@MainActor
@Suite("DS progress bar sweep", .serialized)
struct DSProgressBarSweepTests {
    @Test("every sweep keeps one beat, counted from the reference date, wherever its loop began")
    func sweepsShareABeat() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000 * DSProgressBar.sweepPeriod + 0.35)
        #expect(abs(DSProgressBar.sweepBegin(now: now, layerTime: 50) - 49.65) < 0.000_1)
    }

    @Test("the bar's leading edge runs from a span before the track to its end, evenly, again and again")
    func sweepRunsTheTrack() {
        let sweep = DSProgressBar.sweepAnimation(width: 200, beginTime: 12)
        var start: [Float] = [0, 0], end: [Float] = [0, 0]
        sweep.timingFunction?.getControlPoint(at: 1, values: &start)
        sweep.timingFunction?.getControlPoint(at: 2, values: &end)
        #expect(sweep.keyPath == "transform.translation.x")
        #expect(sweep.fromValue as? CGFloat == -60)
        #expect(sweep.toValue as? CGFloat == 200)
        #expect(sweep.duration == DSProgressBar.sweepPeriod)
        #expect(sweep.beginTime == 12)
        #expect(sweep.repeatCount == .infinity)
        #expect(start == [0, 0] && end == [1, 1], "a linear pace")
    }

    private func sweepViews(in view: NSView) -> [DSProgressBar.SweepView] {
        ((view as? DSProgressBar.SweepView).map { [$0] } ?? []) + view.subviews.flatMap(sweepViews(in:))
    }

    @Test("a bar that can't say how far along it is sweeps on a layer the render server moves; one that can, or Reduce Motion, has none")
    func sweepIsOnALayer() throws {
        let sweeping = HostedWindow(DSProgressBar(value: nil).frame(width: 200), width: 200, height: 6)
        defer { sweeping.close() }
        let view = try #require(sweepViews(in: sweeping.host).first)
        #expect(view.bar.frame.width == 60)
        #expect(view.bar.fillColor != nil)
        #expect(view.bar.animation(forKey: DSProgressBar.sweepKey) != nil)

        let filling = HostedWindow(DSProgressBar(value: 0.4).frame(width: 200), width: 200, height: 6)
        defer { filling.close() }
        #expect(sweepViews(in: filling.host).isEmpty)

        let still = HostedWindow(DSProgressBar(value: nil).frame(width: 200).environment(\._accessibilityReduceMotion, true), width: 200, height: 6)
        defer { still.close() }
        #expect(sweepViews(in: still.host).isEmpty)
    }
}
