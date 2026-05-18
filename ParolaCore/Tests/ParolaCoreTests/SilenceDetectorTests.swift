import Foundation
import Testing
@testable import ParolaCore

@Suite("Silence detector")
struct SilenceDetectorTests {
    @Test("no alert before the threshold elapses")
    func belowThreshold() {
        let start = Date(timeIntervalSince1970: 0)
        var d = SilenceDetector(threshold: 5)
        d.note(active: true, at: start)
        d.note(active: false, at: start.addingTimeInterval(2))
        #expect(d.silenceSeconds(at: start.addingTimeInterval(5)) == 3)
        #expect(d.shouldAlert(at: start.addingTimeInterval(5)) == false)
    }

    @Test("alerts once threshold elapses")
    func aboveThreshold() {
        let start = Date(timeIntervalSince1970: 0)
        var d = SilenceDetector(threshold: 5)
        d.note(active: true, at: start)
        d.note(active: false, at: start.addingTimeInterval(1))
        #expect(d.shouldAlert(at: start.addingTimeInterval(7)) == true)
    }

    @Test("becoming active resets the silence clock")
    func resetsOnActive() {
        let start = Date(timeIntervalSince1970: 0)
        var d = SilenceDetector(threshold: 5)
        d.note(active: false, at: start)
        d.note(active: true, at: start.addingTimeInterval(10))
        d.note(active: false, at: start.addingTimeInterval(20))
        #expect(d.silenceSeconds(at: start.addingTimeInterval(21)) == 1)
        #expect(d.shouldAlert(at: start.addingTimeInterval(21)) == false)
    }

    @Test("reset wipes any pending silence")
    func resetWipes() {
        let start = Date(timeIntervalSince1970: 0)
        var d = SilenceDetector(threshold: 5)
        d.note(active: false, at: start)
        d.reset()
        #expect(d.silenceSeconds(at: start.addingTimeInterval(100)) == 0)
    }

    @Test("idempotent same-state notes don't extend silence beyond their first timestamp")
    func idempotentNotes() {
        let start = Date(timeIntervalSince1970: 0)
        var d = SilenceDetector(threshold: 3)
        d.note(active: false, at: start)
        d.note(active: false, at: start.addingTimeInterval(1))
        d.note(active: false, at: start.addingTimeInterval(2))
        #expect(d.silenceSeconds(at: start.addingTimeInterval(2)) == 2)
        #expect(d.shouldAlert(at: start.addingTimeInterval(4)) == true)
    }
}
