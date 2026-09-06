import Testing

/// Serializes the suites that still share a process-wide override: an installed `ParolaLog` sink, a
/// `FileDiagnosticsSink` whose init-time sweep logs, or `RecordingScratch`'s directory. Suites that
/// only capture their own records scope them with `ParolaLog.withSink` and need no gate. It lives
/// outside both test targets because the gate has to be one instance for the whole test process.
public struct LogFacadeTrait: SuiteTrait, TestTrait, TestScoping {
    public var isRecursive: Bool { true }

    public init() {}

    public func provideScope(
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
    public static var logFacade: Self { Self() }
}

/// Not reentrant: a suite tagged `.logFacade` must never call `acquire` again inside a test.
public actor LogFacadeGate {
    public static let shared = LogFacadeGate()

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public func acquire() async {
        while busy {
            await withCheckedContinuation { waiters.append($0) }
        }
        busy = true
    }

    public func release() {
        busy = false
        let queued = waiters
        waiters = []
        for waiter in queued { waiter.resume() }
    }
}
