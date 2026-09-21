import Foundation
import Testing
@testable import Parola

@Suite("Brand waveform levels")
struct BrandWaveformScaleTests {

    @Test("silence keeps a third of each bar and a full level fills it")
    func floorAndCeiling() {
        #expect(BrandWaveform.scale(level: 0) == 0.35)
        #expect(BrandWaveform.scale(level: 1) == 1)
    }

    @Test("a level outside the range clamps to an end")
    func clampsOutOfRange() {
        #expect(BrandWaveform.scale(level: -0.4) == 0.35)
        #expect(BrandWaveform.scale(level: 2) == 1)
        #expect(BrandWaveform.scale(level: .nan) == 0.35)
    }

    @Test("the bar grows with the level")
    func growsWithTheLevel() {
        #expect(BrandWaveform.scale(level: 0.5) == 0.675)
        let steps = stride(from: Float(0), through: 1, by: 0.125).map { BrandWaveform.scale(level: $0) }
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0 < $1 })
    }
}
