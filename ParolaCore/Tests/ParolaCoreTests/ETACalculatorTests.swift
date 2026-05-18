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

    @Test("formatted ETA reads as M:SS for short jobs and H:MM:SS otherwise")
    func formatting() {
        #expect(ETACalculator.format(45) == "0:45")
        #expect(ETACalculator.format(65) == "1:05")
        #expect(ETACalculator.format(3725) == "1:02:05")
    }
}
