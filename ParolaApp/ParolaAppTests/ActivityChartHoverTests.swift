import Foundation
import Testing
@testable import Parola
import ParolaCore

@MainActor
@Suite("Activity chart hover")
struct ActivityChartHoverTests {
    @Test("every pointer position inside a bucket reads as that bucket")
    func positionsSnapToTheirBucket() {
        let day: TimeInterval = 86_400
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let buckets = (0..<3).map {
            LibraryStatistics.ActivityBucket(start: start.addingTimeInterval(Double($0) * day), entries: 1, audioSeconds: 60)
        }
        let early = ActivityChart.bucket(at: start.addingTimeInterval(day * 1.1), in: buckets)
        let late = ActivityChart.bucket(at: start.addingTimeInterval(day * 1.9), in: buckets)
        #expect(early?.start == buckets[1].start)
        #expect(late?.start == buckets[1].start)
        #expect(ActivityChart.bucket(at: start.addingTimeInterval(-1), in: buckets) == nil)
    }

    @Test("the selection is written only when the pointer moves to another bucket")
    func writesOnlyOnBucketChange() {
        let day: TimeInterval = 86_400
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let buckets = (0..<3).map {
            LibraryStatistics.ActivityBucket(start: start.addingTimeInterval(Double($0) * day), entries: 1, audioSeconds: 60)
        }
        let current = buckets[1].start
        #expect(ActivityChart.selectionWrite(for: current.addingTimeInterval(500), current: current, in: buckets) == nil)
        #expect(ActivityChart.selectionWrite(for: current.addingTimeInterval(day * 0.9), current: current, in: buckets) == nil)
        #expect(ActivityChart.selectionWrite(for: buckets[2].start.addingTimeInterval(5), current: current, in: buckets)?.value == buckets[2].start)
        #expect(ActivityChart.selectionWrite(for: nil, current: current, in: buckets)?.value == nil)
        #expect(ActivityChart.selectionWrite(for: nil, current: nil, in: buckets) == nil)
    }
}
