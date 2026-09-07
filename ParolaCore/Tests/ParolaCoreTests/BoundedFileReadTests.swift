import Foundation
import Testing
@testable import ParolaCore

@Suite("Bounded file reads")
struct BoundedFileReadTests {
    @Test("a read that comes back in time reports its value")
    func fastReadReturnsValue() async {
        let outcome = await BoundedFileRead.run(deadline: .seconds(5)) { 42 }
        guard case .done(let value) = outcome else {
            Issue.record("expected a value, got a timeout")
            return
        }
        #expect(value == 42)
    }

    @Test("a read that never returns stops holding the caller at the deadline")
    func parkedReadTimesOut() async {
        let unblock = DispatchSemaphore(value: 0)
        let started = ContinuousClock.now
        let outcome = await BoundedFileRead.run(deadline: .milliseconds(200)) { () -> Int in
            unblock.wait()
            return 1
        }
        let elapsed = started.duration(to: .now)
        unblock.signal()
        guard case .timedOut = outcome else {
            Issue.record("expected a timeout, got \(outcome)")
            return
        }
        #expect(elapsed < .seconds(3), "the caller waited \(elapsed) past a 200 ms deadline")
    }

    @Test("small files get the header budget and large ones get a proportional one")
    func budgetScalesWithSize() {
        #expect(FileReadDeadline.budget(forBytes: 0) == FileReadDeadline.header)
        #expect(FileReadDeadline.budget(forBytes: 50_000_000) == FileReadDeadline.header)
        #expect(FileReadDeadline.budget(forBytes: 500_000_000) == .seconds(100))
        #expect(FileReadDeadline.budget(forBytes: .max) == FileReadDeadline.ceiling)
    }

    @Test("an unstattable path falls back to the header budget")
    func missingFileGetsHeaderBudget() {
        let url = URL(fileURLWithPath: "/does/not/exist-\(UUID().uuidString)")
        #expect(FileReadDeadline.forReading(url) == FileReadDeadline.header)
    }
}
