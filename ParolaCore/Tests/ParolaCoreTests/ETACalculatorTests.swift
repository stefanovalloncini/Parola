import Foundation
import Testing
@testable import ParolaCore

@Suite("ETA calculator")
struct ETACalculatorTests {
    @Test("returns nil before two samples are observed")
    func nilBeforeSamples() {
        var calc = ETACalculator()
        let start = Date(timeIntervalSince1970: 0)
        calc.observe(progress: 0.0, at: start)
        #expect(calc.remainingSeconds(at: start) == nil)
    }

    @Test("returns nil when progress has not moved")
    func noProgressMovement() {
        var calc = ETACalculator()
        let start = Date(timeIntervalSince1970: 0)
        calc.observe(progress: 0.0, at: start)
        calc.observe(progress: 0.0, at: start.addingTimeInterval(5))
        #expect(calc.remainingSeconds(at: start.addingTimeInterval(5)) == nil)
    }

    @Test("estimates remaining time using observed rate")
    func basicEstimate() {
        var calc = ETACalculator()
        let start = Date(timeIntervalSince1970: 0)
        calc.observe(progress: 0.0, at: start)
        calc.observe(progress: 0.25, at: start.addingTimeInterval(10))
        let remaining = calc.remainingSeconds(at: start.addingTimeInterval(10))
        #expect(remaining == 30)
    }

    @Test("returns zero when progress hits 100 percent")
    func zeroAtCompletion() {
        var calc = ETACalculator()
        let start = Date(timeIntervalSince1970: 0)
        calc.observe(progress: 0.0, at: start)
        calc.observe(progress: 1.0, at: start.addingTimeInterval(40))
        #expect(calc.remainingSeconds(at: start.addingTimeInterval(40)) == 0)
    }

    @Test("returns nil when a near-zero rate makes the estimate non-finite")
    func nonFiniteEstimateIsNil() {
        var calc = ETACalculator()
        let start = Date(timeIntervalSince1970: 0)
        calc.observe(progress: 0.0, at: start)
        calc.observe(progress: .leastNonzeroMagnitude, at: start.addingTimeInterval(1))
        #expect(calc.remainingSeconds(at: start.addingTimeInterval(1)) == nil)
    }

    @Test("formatted ETA reads as M:SS for short jobs and H:MM:SS otherwise")
    func formatting() {
        #expect(ETACalculator.format(45) == "0:45")
        #expect(ETACalculator.format(65) == "1:05")
        #expect(ETACalculator.format(3725) == "1:02:05")
    }

    @Test("formatting saturates on non-finite or out-of-range input instead of trapping")
    func formatSaturatesDegenerateInput() {
        #expect(ETACalculator.format(.nan) == "0:00")
        #expect(ETACalculator.format(-5) == "0:00")
        #expect(ETACalculator.format(.infinity) == ETACalculator.format(.greatestFiniteMagnitude))
    }

    @Test("projected finish is nil before a rate can be estimated")
    func projectedFinishNilBeforeEstimate() {
        var calc = ETACalculator()
        #expect(calc.projectedFinish() == nil)
        calc.observe(progress: 0.0, at: Date(timeIntervalSince1970: 0))
        #expect(calc.projectedFinish() == nil)
    }

    @Test("projected finish equals the raw estimate on the first computable sample")
    func projectedFinishFirstEstimate() {
        var calc = ETACalculator()
        let start = Date(timeIntervalSince1970: 0)
        calc.observe(progress: 0.0, at: start)
        calc.observe(progress: 0.25, at: start.addingTimeInterval(10))
        #expect(calc.projectedFinish() == start.addingTimeInterval(40))
    }

    @Test("projected finish damps toward a jumped estimate instead of snapping")
    func projectedFinishSmoothsUpwardJump() {
        var calc = ETACalculator()
        let start = Date(timeIntervalSince1970: 0)
        calc.observe(progress: 0.0, at: start)
        calc.observe(progress: 0.25, at: start.addingTimeInterval(10))
        calc.observe(progress: 0.25, at: start.addingTimeInterval(20))
        #expect(calc.projectedFinish() == start.addingTimeInterval(60))
    }

    @Test("projected finish is the current sample once progress completes")
    func projectedFinishAtCompletion() {
        var calc = ETACalculator()
        let start = Date(timeIntervalSince1970: 0)
        calc.observe(progress: 0.0, at: start)
        calc.observe(progress: 0.25, at: start.addingTimeInterval(10))
        calc.observe(progress: 1.0, at: start.addingTimeInterval(30))
        #expect(calc.projectedFinish() == start.addingTimeInterval(30))
    }

    @Test("reset clears the projected finish")
    func resetClearsProjectedFinish() {
        var calc = ETACalculator()
        let start = Date(timeIntervalSince1970: 0)
        calc.observe(progress: 0.0, at: start)
        calc.observe(progress: 0.25, at: start.addingTimeInterval(10))
        calc.reset()
        #expect(calc.projectedFinish() == nil)
    }
}
