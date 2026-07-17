import Foundation
import Testing
@testable import ParolaDictation

@Suite("Async timeout race")
struct AsyncTimeoutTests {
    @Test("returns the value when work beats the deadline")
    func workWins() async {
        let value = await AsyncTimeout.run(.seconds(5)) { "fast" }
        #expect(value == "fast")
    }

    @Test("abandons work that ignores cancellation at the deadline")
    func timeoutWinsOverUncancellableWork() async {
        let clock = ContinuousClock()
        let start = clock.now
        let value = await AsyncTimeout.run(.milliseconds(50)) { () -> String in
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    continuation.resume(returning: ())
                }
            }
            return "late"
        }
        let elapsed = clock.now - start
        #expect(value == nil)
        #expect(elapsed < .seconds(2), "the caller must get control back at the deadline, not when the work returns")
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
