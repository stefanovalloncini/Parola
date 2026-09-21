import Clocks
import Foundation
import Testing
@testable import ParolaCore

@Suite("Callback coalescer")
struct CallbackCoalescerTests {
    @Test("the first value is emitted immediately")
    func firstValuePassesThrough() {
        var coalescer = CallbackCoalescer<String>(minimumInterval: .milliseconds(100), clock: TestClock())
        let first = coalescer.offer("one")
        #expect(first == "one")
    }

    @Test("values offered inside the interval are withheld")
    func burstIsWithheld() {
        let clock = TestClock()
        var coalescer = CallbackCoalescer<String>(minimumInterval: .milliseconds(100), clock: clock)
        let first = coalescer.offer("one")
        clock.advance(by: .milliseconds(10))
        let second = coalescer.offer("two")
        clock.advance(by: .milliseconds(10))
        let third = coalescer.offer("three")
        #expect(first == "one")
        #expect(second == nil)
        #expect(third == nil)
    }

    @Test("a burst of many values costs one emission and one flush")
    func burstEmitsOnceThenFlushesTheLast() {
        let clock = TestClock()
        var coalescer = CallbackCoalescer<Int>(minimumInterval: .milliseconds(100), clock: clock)
        var emitted: [Int] = []
        for value in 0..<50 {
            if let ready = coalescer.offer(value) { emitted.append(ready) }
            clock.advance(by: .milliseconds(1))
        }
        let tail = coalescer.flush()
        #expect(emitted == [0])
        #expect(tail == 49)
    }

    @Test("a value offered after the interval is emitted")
    func spacedValuePassesThrough() {
        let clock = TestClock()
        var coalescer = CallbackCoalescer<String>(minimumInterval: .milliseconds(100), clock: clock)
        _ = coalescer.offer("one")
        clock.advance(by: .milliseconds(100))
        let second = coalescer.offer("two")
        let tail = coalescer.flush()
        #expect(second == "two")
        #expect(tail == nil)
    }

    @Test("an interval-spaced sequence passes every value through")
    func spacedSequencePassesEveryValue() {
        let clock = TestClock()
        var coalescer = CallbackCoalescer<Int>(minimumInterval: .milliseconds(100), clock: clock)
        var emitted: [Int] = []
        for value in 0..<5 {
            if let ready = coalescer.offer(value) { emitted.append(ready) }
            clock.advance(by: .milliseconds(120))
        }
        let tail = coalescer.flush()
        #expect(emitted == [0, 1, 2, 3, 4])
        #expect(tail == nil)
    }

    @Test("flush yields nothing when every value was already emitted")
    func flushIsEmptyWithoutWithheldValues() {
        var coalescer = CallbackCoalescer<String>(minimumInterval: .milliseconds(100), clock: TestClock())
        _ = coalescer.offer("one")
        let tail = coalescer.flush()
        #expect(tail == nil)
    }

    @Test("flush yields the withheld value exactly once")
    func flushYieldsOnce() {
        let clock = TestClock()
        var coalescer = CallbackCoalescer<String>(minimumInterval: .milliseconds(100), clock: clock)
        _ = coalescer.offer("one")
        clock.advance(by: .milliseconds(10))
        _ = coalescer.offer("two")
        let first = coalescer.flush()
        let second = coalescer.flush()
        #expect(first == "two")
        #expect(second == nil)
    }

    @Test("the interval still gates values offered after a flush")
    func intervalSurvivesAFlush() {
        let clock = TestClock()
        var coalescer = CallbackCoalescer<String>(minimumInterval: .milliseconds(100), clock: clock)
        _ = coalescer.offer("one")
        clock.advance(by: .milliseconds(10))
        _ = coalescer.offer("two")
        _ = coalescer.flush()
        clock.advance(by: .milliseconds(10))
        let third = coalescer.offer("three")
        clock.advance(by: .milliseconds(100))
        let fourth = coalescer.offer("four")
        #expect(third == nil)
        #expect(fourth == "four")
    }

    @Test("a coalescer with no clock of its own uses the continuous clock")
    func defaultClockIsContinuous() {
        var coalescer = CallbackCoalescer<String>(minimumInterval: .seconds(30))
        let first = coalescer.offer("one")
        let second = coalescer.offer("two")
        let tail = coalescer.flush()
        #expect(first == "one")
        #expect(second == nil)
        #expect(tail == "two")
    }
}
