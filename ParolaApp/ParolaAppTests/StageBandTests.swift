import Foundation
import Testing
@testable import Parola

@Suite("Stage band")
struct StageBandTests {
    @Test("the playhead stands at 70 % of the band on a whole point")
    func playhead() {
        #expect(StageBand.playheadX(width: 1180) == 826)
        #expect(StageBand.playheadX(width: 920) == 644)
    }

    @Test("the newest bar sits against the playhead and each older one 5 pt further left")
    func barsStepLeft() {
        #expect(StageBand.barX(offset: 0, playheadX: 826) == 821)
        #expect(StageBand.barX(offset: 1, playheadX: 826) == 816)
        #expect(StageBand.barX(offset: 10, playheadX: 826) == 771)
    }

    @Test("a marker stands at its moment in the take until it scrolls out of the band")
    func markers() {
        #expect(StageBand.markerOffset(10.0, newestSample: 99) == 0)
        #expect(StageBand.markerOffset(10.4, newestSample: 99) == 0)
        #expect(StageBand.markerOffset(8.0, newestSample: 99) == 19)
        #expect(StageBand.markerOffset(0, newestSample: StageBand.visibleSamples - 1) == StageBand.visibleSamples - 1)
        #expect(StageBand.markerOffset(0, newestSample: StageBand.visibleSamples) == nil)
    }

    @MainActor
    @Test("a take's levels keep every sample the band can show")
    func historyCoversTheBand() {
        #expect(TakeLevelHistory().recentCapacity >= StageBand.visibleSamples)
    }

    @Test("quiet levels still lift the bars, silence rests at the idle height")
    func barCurve() {
        #expect(LevelBars.height(for: 0, idle: 3, max: 124) == 3)
        #expect(LevelBars.height(for: 1, idle: 3, max: 124) == 124)
        #expect(LevelBars.height(for: 0.25, idle: 3, max: 124) > 3 + (124 - 3) * 0.25)
        #expect(LevelBars.height(for: 2, idle: 3, max: 124) == 124)
    }
}
