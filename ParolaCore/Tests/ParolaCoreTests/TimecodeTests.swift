import Foundation
import Testing
@testable import ParolaCore

@Suite("Timecode")
struct TimecodeTests {
    @Test("MM:SS under an hour")
    func underAnHour() {
        #expect(Timecode.format(0) == "00:00")
        #expect(Timecode.format(5) == "00:05")
        #expect(Timecode.format(65) == "01:05")
        #expect(Timecode.format(3599) == "59:59")
    }

    @Test("H:MM:SS over an hour")
    func overAnHour() {
        #expect(Timecode.format(3600) == "1:00:00")
        #expect(Timecode.format(3665) == "1:01:05")
        let twoHFiveMSeven = 2 * 3600 + 5 * 60 + 7
        #expect(Timecode.format(Double(twoHFiveMSeven)) == "2:05:07")
    }

    @Test("saturates instead of trapping past Int range")
    func saturatesOnOverflow() {
        let huge = Timecode.format(1e19)
        #expect(huge.filter { $0 == ":" }.count == 2)
        #expect(!huge.isEmpty)
        #expect(Timecode.format(.infinity).filter { $0 == ":" }.count == 2)
    }

    @Test("clamps non-finite and negative input to zero")
    func clampsNonFiniteAndNegative() {
        #expect(Timecode.format(.nan) == "00:00")
        #expect(Timecode.format(-5) == "00:00")
    }

    @Test("parse returns nil instead of trapping when a field overflows Int")
    func parseOverflows() {
        #expect(Timecode.parse("200000000000000000:0") == nil)
        #expect(Timecode.parse("9000000000000000000:0:0") == nil)
    }

    @Test("parse still accepts a large in-range timecode")
    func parseLargeInRange() {
        #expect(Timecode.parse("1000:00:00") == 3_600_000)
    }
}
