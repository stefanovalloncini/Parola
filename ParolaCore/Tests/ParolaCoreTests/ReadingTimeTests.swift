import Foundation
import Testing
@testable import ParolaCore

@Suite("Reading time")
struct ReadingTimeTests {
    @Test("computes minutes at 200 wpm")
    func basic() {
        #expect(ReadingTime.minutes(forWordCount: 400) == 2)
    }

    @Test("rounds up so any reading takes at least a minute")
    func roundUp() {
        #expect(ReadingTime.minutes(forWordCount: 50) == 1)
    }

    @Test("zero words is zero minutes")
    func zero() {
        #expect(ReadingTime.minutes(forWordCount: 0) == 0)
    }

    @Test("formats labels with a min suffix")
    func formatLabel() {
        #expect(ReadingTime.label(forMinutes: 1) == "1 min")
        #expect(ReadingTime.label(forMinutes: 10) == "10 min")
        #expect(ReadingTime.label(forMinutes: 65) == "1h 5m")
    }

    @Test("zero minutes label says less than a minute")
    func zeroLabel() {
        #expect(ReadingTime.label(forMinutes: 0) == "—")
    }
}
