import Foundation
import Observation
import Testing
@testable import Parola

@MainActor
@Observable
private final class Probe {
    var n: Int = 0
}

@MainActor
@Suite("AsyncObservation.changes")
struct AsyncObservationTests {

    @Test("yields the current value immediately on subscription")
    func yieldsInitialValue() async {
        let probe = Probe()
        probe.n = 7
        let stream = AsyncObservation.changes { probe.n }
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first == 7)
    }

    @Test("yields again after the tracked property mutates")
    func yieldsOnMutation() async {
        let probe = Probe()
        let stream = AsyncObservation.changes { probe.n }
        var iterator = stream.makeAsyncIterator()

        let first = await iterator.next()
        #expect(first == 0)

        probe.n += 1

        let second = await iterator.next()
        #expect(second == 1)
    }

    @Test("for-await loop terminates once a predicate matches")
    func breakOnPredicate() async {
        let probe = Probe()
        let stream = AsyncObservation.changes { probe.n }

        let mutate = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(5), clock: ContinuousClock())
            probe.n = 42
        }

        var matched: Int = -1
        for await value in stream where value == 42 {
            matched = value
            break
        }
        await mutate.value

        #expect(matched == 42)
    }
}
