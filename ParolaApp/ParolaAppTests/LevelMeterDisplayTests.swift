import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore

@Suite("Level meter display")
struct LevelMeterDisplayTests {
    @Test("the display clock runs while the capture hears sound and rests a second after it stops")
    func stepFollowsTheSound() {
        let now = ContinuousClock.now
        #expect(LevelMeterSchedule.step(lastSound: now, now: now, mode: .normal) == LevelMeterSchedule.interval)
        #expect(LevelMeterSchedule.step(lastSound: now - .milliseconds(900), now: now, mode: .normal) == LevelMeterSchedule.interval)
        #expect(LevelMeterSchedule.step(lastSound: now - .milliseconds(1100), now: now, mode: .normal) == LevelMeterSchedule.restingPoll)
        #expect(LevelMeterSchedule.step(lastSound: nil, now: now, mode: .normal) == LevelMeterSchedule.restingPoll)
        #expect(LevelMeterSchedule.step(lastSound: now, now: now, mode: .lowFrequency) == 1)
    }

    @Test("frames follow the meter as each one is asked for, on the grid they started on")
    func entriesReadTheMeterAsTheyGo() {
        let meter = LevelMeter()
        let start = Date()
        var entries = LevelMeterSchedule(meter: meter).entries(from: start, mode: .normal).makeIterator()

        let opening = entries.next()
        let resting = entries.next()
        #expect(opening == start)
        #expect(resting == start.addingTimeInterval(LevelMeterSchedule.restingPoll))

        meter.record(0.5)
        let first = entries.next()
        let second = entries.next()
        if let first, let second {
            #expect(abs(second.timeIntervalSince(first) - LevelMeterSchedule.interval) < 0.000_1)
        }
    }

    @Test("a frame samples the meter once, however often it is drawn, and keeps the peak between frames")
    @MainActor
    func traceSamplesOncePerFrame() {
        let meter = LevelMeter()
        let trace = LevelTrace(capacity: 4)
        let frame = Date()

        meter.record(0.9)
        meter.record(0.2)
        #expect(trace.samples(at: frame, reading: meter) == [0, 0, 0, 0.9])
        meter.record(0.7)
        #expect(trace.samples(at: frame, reading: meter) == [0, 0, 0, 0.9], "the same frame drawn twice")
        #expect(trace.samples(at: frame.addingTimeInterval(1), reading: meter) == [0, 0, 0.9, 0.7])
    }
}
