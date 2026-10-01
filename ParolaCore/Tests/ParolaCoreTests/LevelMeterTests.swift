import Foundation
import Testing
@testable import ParolaCore

@Suite("Level meter")
struct LevelMeterTests {
    @Test("it holds the latest level, the peak since the last read, and when sound was last heard")
    func latestPeakAndLastSound() {
        let meter = LevelMeter()
        #expect(meter.level == 0)
        #expect(meter.lastSound == nil)

        meter.record(0.01)
        #expect(meter.lastSound == nil, "below the floor is not sound")
        meter.record(0.2)
        meter.record(0.8)
        meter.record(0.3)
        #expect(meter.level == 0.3)
        #expect(meter.takePeak() == 0.8)
        #expect(meter.takePeak() == 0.3, "the next read starts from the latest level")
        #expect(meter.lastSound != nil)
    }

    @Test("a reading outside 0...1 is clamped and a NaN reads as silence")
    func clampsItsInput() {
        let meter = LevelMeter()
        meter.record(3)
        #expect(meter.level == 1)
        meter.record(-1)
        #expect(meter.level == 0)
        meter.record(.nan)
        #expect(meter.level == 0)
    }

    @Test("a reset forgets the level, the peak and the last sound")
    func resetClearsEverything() {
        let meter = LevelMeter()
        meter.record(0.7)
        meter.reset()
        #expect(meter.level == 0)
        #expect(meter.takePeak() == 0)
        #expect(meter.lastSound == nil)
    }

    @Test("an RMS maps onto the same scale a captured buffer does")
    func rmsScale() {
        #expect(AudioLevel.normalised(rms: 1) == 1)
        #expect(AudioLevel.normalised(rms: 0) == 0)
        #expect(abs(AudioLevel.normalised(rms: 0.1) - 35.0 / 55.0) < 0.0001)
    }
}

@Suite("Level meter first reading")
struct LevelMeterFirstReadingTests {
    @Test("the meter remembers when its first reading came in, even a silent one")
    func firstReading() {
        let meter = LevelMeter()
        #expect(meter.firstReadingAt == nil)
        meter.record(0)
        let first = meter.firstReadingAt
        #expect(first != nil)
        meter.record(0.5)
        #expect(meter.firstReadingAt == first)
        meter.reset()
        #expect(meter.firstReadingAt == nil)
    }

    @Test("the meter remembers when its latest reading came in, silent or not, and a reset forgets it")
    func lastReading() async throws {
        let meter = LevelMeter()
        #expect(meter.lastReadingAt == nil)
        meter.record(0)
        let first = try #require(meter.lastReadingAt)
        try await Task.sleep(for: .milliseconds(5))
        meter.record(0)
        let latest = try #require(meter.lastReadingAt)
        #expect(latest > first)
        #expect(meter.firstReadingAt == first)
        meter.reset()
        #expect(meter.lastReadingAt == nil)
    }
}
