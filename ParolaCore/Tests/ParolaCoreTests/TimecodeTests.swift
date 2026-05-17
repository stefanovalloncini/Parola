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
}
