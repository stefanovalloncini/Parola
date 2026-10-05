import Foundation
import Testing
@testable import ParolaCore

@Suite("Idle unload timer")
struct IdleUnloadTimerTests {
    @Test("fires once after the duration")
    func firesOnceAfterTheDuration() async {
        let clock = TestClock()
        let fired = Awaitable<[Int]>([])
        var timer = IdleUnloadTimer()
        timer.arm(after: .seconds(600), clock: clock) { epoch in fired.update { $0.append(epoch) } }
        await clock.waitForSleeper()

        clock.advance(by: .seconds(599))
        #expect(clock.sleeperCount == 1, "still asleep a second short of the duration")
        #expect(fired.value.isEmpty)

        clock.advance(by: .seconds(1))
        await fired.wait(until: { $0.count == 1 }, "the timer to fire")
        clock.advance(by: .seconds(600))
        #expect(clock.sleeperCount == 0, "nothing re-arms after a fire")
        #expect(fired.value.count == 1)
    }

    @Test("a re-arm cancels the earlier one")
    func reArmCancelsTheEarlierOne() async {
        let clock = TestClock()
        let fired = Awaitable<[Int]>([])
        var timer = IdleUnloadTimer()
        timer.arm(after: .seconds(600), clock: clock) { epoch in fired.update { $0.append(epoch) } }
        await clock.waitForSleeper()
        clock.advance(by: .seconds(300))

        timer.arm(after: .seconds(600), clock: clock) { epoch in fired.update { $0.append(epoch) } }
        await clock.waitForSleeper()
        #expect(clock.sleeperCount == 1, "the first timer's sleep was cancelled")

        clock.advance(by: .seconds(300))
        #expect(fired.value.isEmpty, "the first deadline passed without a fire")
        clock.advance(by: .seconds(300))
        await fired.wait(until: { $0.count == 1 }, "the second timer to fire")
        #expect(fired.value.count == 1)
        #expect(fired.value.allSatisfy { timer.isCurrent($0) })
    }

    @Test("disarm prevents firing")
    func disarmPreventsFiring() async {
        let clock = TestClock()
        let fired = Awaitable<[Int]>([])
        var timer = IdleUnloadTimer()
        timer.arm(after: .seconds(600), clock: clock) { epoch in fired.update { $0.append(epoch) } }
        await clock.waitForSleeper()

        timer.disarm()
        #expect(clock.sleeperCount == 0, "the armed sleep was cancelled")
        clock.advance(by: .seconds(1_200))
        #expect(fired.value.isEmpty)
    }

    @Test("isCurrent follows the epoch")
    func isCurrentFollowsTheEpoch() async {
        let clock = TestClock()
        let fired = Awaitable<[Int]>([])
        var timer = IdleUnloadTimer()
        timer.arm(after: .seconds(600), clock: clock) { epoch in fired.update { $0.append(epoch) } }
        await clock.waitForSleeper()
        clock.advance(by: .seconds(600))
        await fired.wait(until: { $0.count == 1 }, "the timer to fire")
        let epoch = fired.value[0]
        #expect(timer.isCurrent(epoch))

        timer.disarm()
        #expect(!timer.isCurrent(epoch), "a disarm retires the fired epoch")

        timer.arm(after: .seconds(600), clock: clock) { _ in }
        #expect(!timer.isCurrent(epoch), "a new arm never revives an old epoch")
        timer.disarm()
    }
}
