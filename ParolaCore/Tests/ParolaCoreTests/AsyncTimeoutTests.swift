import Foundation
import Testing
import os
@testable import ParolaCore

@Suite("Async timeout race")
struct AsyncTimeoutTests {
    @Test("returns the value when work beats the deadline")
    func workWins() async {
        let value = await AsyncTimeout.run(.seconds(5)) { "fast" }
        #expect(value == "fast")
    }

    @Test("abandons work that ignores cancellation at the deadline")
    func timeoutWinsOverUncancellableWork() async {
        let clock = TestClock()
        let workFinished = OSAllocatedUnfairLock(initialState: false)
        async let raced = AsyncTimeout.run(.milliseconds(50), clock: clock) { () -> String in
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    continuation.resume(returning: ())
                }
            }
            workFinished.withLock { $0 = true }
            return "late"
        }

        await clock.waitForSleeper()
        clock.advance(by: .milliseconds(50))

        #expect(await raced == nil)
        #expect(
            workFinished.withLock { $0 } == false,
            "the caller must get control back at the deadline, not when the work returns"
        )
    }

    @Test("cancellable work is cancelled at the deadline")
    func timeoutCancelsResponsiveWork() async {
        let value = await AsyncTimeout.run(.milliseconds(50)) { () -> String in
            try? await Task.sleep(for: .seconds(30))
            return Task.isCancelled ? "cancelled" : "slept"
        }
        #expect(value == nil)
    }
}
