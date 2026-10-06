import AVFoundation
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

    @Test("waiting for seconds of audio counts from the first reading, however late it comes")
    func waitForAudioCountsFromTheFirstReading() async throws {
        let clock = TestClock()
        let meter = LevelMeter()
        let waiting = GuardedTask { await meter.waitForAudio(seconds: 5, clock: clock) }
        await clock.waitForSleeper()
        clock.advance(by: .seconds(30))
        await clock.waitForSleeper()
        #expect(!waiting.isFinished, "no audio has come in yet")

        meter.record(0.5)
        clock.advance(by: .milliseconds(50))
        await clock.waitForSleeper()
        clock.advance(by: .seconds(4))
        await clock.waitForSleeper()
        #expect(!waiting.isFinished, "four seconds of audio so far")
        clock.advance(by: .seconds(1))

        _ = try await waiting.value("the wait to end five seconds after the first reading")
    }

    @Test("with a limit, waiting for audio ends once that long passes with no reading")
    func waitForAudioGivesUpWithoutAudio() async throws {
        let clock = TestClock()
        let meter = LevelMeter()
        let waiting = GuardedTask { await meter.waitForAudio(seconds: 5, noAudioLimit: .seconds(1), clock: clock) }
        for _ in 0..<19 {
            await clock.waitForSleeper()
            clock.advance(by: .milliseconds(50))
        }
        await clock.waitForSleeper()
        #expect(!waiting.isFinished, "still within the limit")
        clock.advance(by: .milliseconds(50))

        _ = try await waiting.value("the wait to give up after a second with no audio")
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

    @Test("a first reading keeps when its audio was captured, not when it was metered; later ones change neither")
    func firstReadingKeepsItsCaptureTime() {
        let meter = LevelMeter()
        let captured = ContinuousClock.now - .milliseconds(85)

        meter.record(0.2, capturedAt: captured)
        meter.record(0.3, capturedAt: ContinuousClock.now)

        #expect(meter.firstReadingAt == captured)
        let arrived = meter.lastReadingAt.map { $0 > captured } ?? false
        #expect(arrived, "the latest reading is when it came in")
    }

    @Test("a tap's host time turns into the continuous-clock moment its first sample was heard")
    func hostTimeBecomesAnInstant() {
        let now = mach_absolute_time()
        let clockNow = ContinuousClock.now
        let hostTime = now - AVAudioTime.hostTime(forSeconds: 0.085)

        let heard = MicAudioSource.instant(ofHostTime: hostTime, now: now, clockNow: clockNow)

        let ago = heard.duration(to: clockNow)
        #expect(abs(Double(ago.components.attoseconds) / 1e18 + Double(ago.components.seconds) - 0.085) < 0.001)
        #expect(MicAudioSource.instant(ofHostTime: now + 10, now: now, clockNow: clockNow) == clockNow)
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
