import Testing

/// Serializes the suites that still install a `ParolaLog` sink process-wide; scoped ones need no gate.
struct LogFacadeTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        await LogFacadeGate.shared.acquire()
        do {
            try await function()
        } catch {
            await LogFacadeGate.shared.release()
            throw error
        }
        await LogFacadeGate.shared.release()
    }
}

extension Trait where Self == LogFacadeTrait {
    static var logFacade: Self { Self() }
}

/// Not reentrant: a suite tagged `.logFacade` must never call `acquire` again inside a test.
actor LogFacadeGate {
    static let shared = LogFacadeGate()

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        while busy {
            await withCheckedContinuation { waiters.append($0) }
        }
        busy = true
    }

    func release() {
        busy = false
        let queued = waiters
        waiters = []
        for waiter in queued { waiter.resume() }
    }
}

// Deliberately untagged — the gate is not reentrant, so tagging this suite would deadlock it.
@Suite("App log facade gate")
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
