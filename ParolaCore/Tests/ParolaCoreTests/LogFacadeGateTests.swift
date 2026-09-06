import Testing
import ParolaTestSupport

/// Deliberately untagged — the gate is not reentrant, so tagging this suite would deadlock it.
@Suite("Log facade gate")
struct LogFacadeGateTests {
    private actor Occupancy {
        private var current = 0
        private(set) var peak = 0

        func enter() {
            current += 1
            peak = max(peak, current)
        }

        func exit() { current -= 1 }
    }

    @Test("only one holder is inside the gate at a time")
    func excludesConcurrentHolders() async {
        let occupancy = Occupancy()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await LogFacadeGate.shared.acquire()
                    await occupancy.enter()
                    try? await Task.sleep(for: .milliseconds(5))
                    await occupancy.exit()
                    await LogFacadeGate.shared.release()
                }
            }
        }
        #expect(await occupancy.peak == 1)
    }
}
