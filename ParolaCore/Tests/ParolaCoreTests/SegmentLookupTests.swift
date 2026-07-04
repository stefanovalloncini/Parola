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

    @Test("firstSegment(startingAfter:) returns the first segment whose start is past the threshold")
    func firstStartingAfter() {
        let segments = [
            TranscriptSegment(id: 1, start: 0, end: 1, text: "a"),
            TranscriptSegment(id: 2, start: 1, end: 2, text: "b"),
            TranscriptSegment(id: 3, start: 5, end: 6, text: "c"),
        ]
        #expect(segments.firstSegment(startingAfter: 1.4)?.id == 3)
        #expect(segments.firstSegment(startingAfter: 0)?.id == 2)
        #expect(segments.firstSegment(startingAfter: 5) == nil)
        #expect(segments.firstSegment(startingAfter: -1)?.id == 1)
        #expect([TranscriptSegment]().firstSegment(startingAfter: 0) == nil)
    }

    @Test("firstSegment(startingAfter:) agrees with a linear scan across a large set")
    func firstStartingAfterParity() {
        let segments = (0..<1000).map {
            TranscriptSegment(id: $0, start: Double($0), end: Double($0) + 0.9, text: "")
        }
        for t in stride(from: -1.0, through: 1001.0, by: 7.3) {
            let expected = segments.first(where: { $0.start > t })?.id
            #expect(segments.firstSegment(startingAfter: t)?.id == expected)
        }
    }

    @Test("index variant agrees with the segment variant")
    func indexVariantAgrees() {
        let segments = [
            TranscriptSegment(id: 1, start: 0, end: 1, text: "a"),
            TranscriptSegment(id: 2, start: 1.5, end: 2, text: "b"),
            TranscriptSegment(id: 3, start: 2, end: 3, text: "c"),
        ]
        for t in stride(from: -0.5, through: 3.5, by: 0.25) {
            let idx = segments.binarySearchSegmentIndex(coveringTime: t)
            #expect(idx.map { segments[$0] } == segments.binarySearchSegment(coveringTime: t))
        }
        #expect([TranscriptSegment]().binarySearchSegmentIndex(coveringTime: 1) == nil)
    }
}
