import Foundation
import Testing
@testable import ParolaCore

@Suite("Segment lookup binary search")
struct SegmentLookupTests {
    @Test("finds segment covering exact start")
    func startTime() {
        let segments = [
            TranscriptSegment(id: 1, start: 0, end: 1, text: "a"),
            TranscriptSegment(id: 2, start: 1, end: 2, text: "b"),
            TranscriptSegment(id: 3, start: 2, end: 3, text: "c"),
        ]
        #expect(segments.binarySearchSegment(coveringTime: 0)?.id == 1)
        #expect(segments.binarySearchSegment(coveringTime: 1.5)?.id == 2)
        #expect(segments.binarySearchSegment(coveringTime: 2.9)?.id == 3)
    }

    @Test("returns nil for time outside any segment")
    func outside() {
        let segments = [
            TranscriptSegment(id: 1, start: 0, end: 1, text: "a"),
            TranscriptSegment(id: 2, start: 2, end: 3, text: "b"),
        ]
        #expect(segments.binarySearchSegment(coveringTime: 1.5) == nil)
        #expect(segments.binarySearchSegment(coveringTime: -1) == nil)
        #expect(segments.binarySearchSegment(coveringTime: 5) == nil)
    }

    @Test("empty segments returns nil")
    func empty() {
        let segments: [TranscriptSegment] = []
        #expect(segments.binarySearchSegment(coveringTime: 0) == nil)
    }

    @Test("works on a large sorted set")
    func large() {
        let segments = (0..<1000).map {
            TranscriptSegment(id: $0, start: Double($0), end: Double($0) + 0.9, text: "")
        }
        #expect(segments.binarySearchSegment(coveringTime: 500.5)?.id == 500)
        #expect(segments.binarySearchSegment(coveringTime: 999.5)?.id == 999)
    }
}
