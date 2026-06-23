import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("Segment start timecode")
struct SegmentTimecodeTests {
    @Test("floors fractional seconds instead of rounding up")
    func floorsFractionalSeconds() {
        #expect(TranscriptDetailView.segmentTimecode(22.8) == "00:22")
        #expect(TranscriptDetailView.segmentTimecode(14.9) == "00:14")
    }

    @Test("zero-pads minutes")
    func zeroPadsMinutes() {
        #expect(TranscriptDetailView.segmentTimecode(0) == "00:00")
        #expect(TranscriptDetailView.segmentTimecode(5) == "00:05")
    }

    @Test("switches to H:MM:SS past an hour and still floors")
    func hoursFloor() {
        #expect(TranscriptDetailView.segmentTimecode(3605.5) == "1:00:05")
    }

    @Test("matches the house Timecode.format used by the sibling list views")
    func matchesTimecodeFormat() {
        for s in [0.0, 5.4, 22.8, 599.9, 3600, 3605.5, 7199.2] {
            #expect(TranscriptDetailView.segmentTimecode(s) == Timecode.format(s))
        }
    }
}
