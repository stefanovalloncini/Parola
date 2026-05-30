import Foundation
import Testing
@testable import ParolaCore

@Suite("Diarization speaker matching")
struct DiarizationMatchTests {
    @Test("overlap matching picks the most-overlapping interval")
    func overlapMatching() {
        let ivs = [(start: 0.0, end: 2.0), (start: 2.0, end: 5.0)]
        #expect(DiarizationService.bestMatchIndex(start: 0.5, end: 1.5, intervals: ivs) == 0)
        #expect(DiarizationService.bestMatchIndex(start: 3.0, end: 4.0, intervals: ivs) == 1)
        #expect(DiarizationService.bestMatchIndex(start: 9.0, end: 10.0, intervals: ivs) == nil)
    }

    @Test("a zero-duration word is matched by containment, not overlap")
    func zeroDurationContainment() {
        let ivs = [(start: 0.0, end: 4.0)]
        #expect(DiarizationService.bestMatchIndex(start: 2.0, end: 2.0, intervals: ivs) == 0)
        #expect(DiarizationService.bestMatchIndex(start: 0.0, end: 0.0, intervals: ivs) == 0)
        #expect(DiarizationService.bestMatchIndex(start: 5.0, end: 5.0, intervals: ivs) == nil)
    }
}
