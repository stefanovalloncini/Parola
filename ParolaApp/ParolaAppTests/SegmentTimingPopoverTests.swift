import Testing
@testable import Parola

@MainActor
@Suite("Segment timing popover frame rate")
struct SegmentTimingPopoverTests {
    @Test("the stepper moves to the neighbouring rate")
    func stepsToNeighbours() {
        #expect(SegmentTimingPopover.fps(above: 30) == 50)
        #expect(SegmentTimingPopover.fps(below: 30) == 29.97)
        #expect(SegmentTimingPopover.fps(above: 23.976) == 24)
        #expect(SegmentTimingPopover.fps(below: 25) == 24)
    }

    @Test("the stepper stops at the slowest and fastest rates")
    func stopsAtTheEnds() {
        #expect(SegmentTimingPopover.fps(below: 23.976) == nil)
        #expect(SegmentTimingPopover.fps(above: 60) == nil)
    }

    @Test("a rate outside the list steps to the nearest listed one on either side")
    func unlistedRate() {
        #expect(SegmentTimingPopover.fps(above: 48) == 50)
        #expect(SegmentTimingPopover.fps(below: 48) == 30)
    }
}
