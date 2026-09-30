import Foundation
import Testing
import os

/// State a test awaits instead of polling. A wait gives up on cancellation or at `timeout` and records an issue, so it never hangs the run.
final class Awaitable<Value: Sendable>: Sendable {
    private enum Outcome: Sendable {
        case met, timedOut, cancelled
    }

    private struct Waiter: Sendable {
        let id: UUID
        let isMet: @Sendable (Value) -> Bool
        let continuation: CheckedContinuation<Outcome, Never>
    }

    private struct State: Sendable {
        var value: Value
        var waiters: [Waiter] = []
        var abandoned: [UUID: Outcome] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ value: Value) {
        state = OSAllocatedUnfairLock(initialState: State(value: value))
    }

    var value: Value { state.withLock { $0.value } }

    func update(_ change: @Sendable (inout Value) -> Void) {
        let ready = state.withLock { state -> [CheckedContinuation<Outcome, Never>] in
            change(&state.value)
            let value = state.value
            var ready: [CheckedContinuation<Outcome, Never>] = []
            state.waiters.removeAll { waiter in
                guard waiter.isMet(value) else { return false }
                ready.append(waiter.continuation)
                return true
            }
            return ready
        }
        for continuation in ready { continuation.resume(returning: .met) }
    }

    @discardableResult
    func wait(
        until isMet: @escaping @Sendable (Value) -> Bool,
        _ description: String,
        timeout: Duration = .seconds(30),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.abandon(id, as: .timedOut)
        }
        defer { timer.cancel() }
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                let settled = state.withLock { state -> Outcome? in
                    if isMet(state.value) { return .met }
                    if let early = state.abandoned.removeValue(forKey: id) { return early }
                    state.waiters.append(Waiter(id: id, isMet: isMet, continuation: continuation))
                    return nil
                }
                if let settled { continuation.resume(returning: settled) }
            }
        } onCancel: {
            abandon(id, as: .cancelled)
        }
        switch outcome {
        case .met:
            return true
        case .timedOut:
            Issue.record("gave up after \(timeout) waiting for \(description)", sourceLocation: sourceLocation)
            return false
        case .cancelled:
            Issue.record("cancelled while waiting for \(description)", sourceLocation: sourceLocation)
            return false
        }
    }

    private func abandon(_ id: UUID, as outcome: Outcome) {
        let parked = state.withLock { state -> CheckedContinuation<Outcome, Never>? in
            if let index = state.waiters.firstIndex(where: { $0.id == id }) {
                return state.waiters.remove(at: index).continuation
            }
            state.abandoned[id] = outcome
            return nil
        }
        parked?.resume(returning: outcome)
    }
}

typealias TestSignal = Awaitable<Bool>

extension Awaitable where Value == Bool {
    convenience init() { self.init(false) }

    var fired: Bool { value }

    func fire() { update { $0 = true } }

    @discardableResult
    func wait(
        _ description: String,
        timeout: Duration = .seconds(30),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        await wait(until: { $0 }, description, timeout: timeout, sourceLocation: sourceLocation)
    }
}

extension Awaitable where Value == Int {
    func increment() { update { $0 += 1 } }

    @discardableResult
    func wait(
        atLeast count: Int,
        _ description: String,
        timeout: Duration = .seconds(30),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        await wait(until: { $0 >= count }, description, timeout: timeout, sourceLocation: sourceLocation)
    }
}

/// Work a test starts now and collects later: work that never finishes records an issue and is cancelled and left behind.
final class GuardedTask<Success: Sendable>: Sendable {
    private let outcome: Awaitable<Result<Success, any Error>?>
    private let task: Task<Void, Never>

    init(_ operation: @escaping @Sendable () async throws -> Success) {
        let outcome = Awaitable<Result<Success, any Error>?>(nil)
        self.outcome = outcome
        task = Task {
            let result: Result<Success, any Error>
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }
            outcome.update { $0 = result }
        }
    }

    var isFinished: Bool { outcome.value != nil }

    func cancel() { task.cancel() }

    /// nil when the work did not finish in time; its error when it threw.
    func value(
        _ description: String,
        timeout: Duration = .seconds(30),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> Success? {
        guard await outcome.wait(
            until: { $0 != nil }, description, timeout: timeout, sourceLocation: sourceLocation
        ) else {
            task.cancel()
            return nil
        }
        return try outcome.value?.get()
    }
}

/// For state no event announces: re-checks it on a short interval under the same guards as `Awaitable.wait`.
@discardableResult
func pollUntil(
    _ description: String,
    timeout: Duration = .seconds(30),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !Task.isCancelled, ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    if await condition() { return true }
    let reason = Task.isCancelled ? "cancelled" : "gave up after \(timeout)"
    Issue.record("\(reason) waiting for \(description)", sourceLocation: sourceLocation)
    return false
}

/// Parks callers, deaf to cancellation, until opened: a stand-in for a read or engine call nothing can interrupt.
final class UninterruptibleGate: Sendable {
    let arrivals = Awaitable(0)
    private let state = OSAllocatedUnfairLock(
        initialState: (opened: false, waiters: [CheckedContinuation<Void, Never>]())
    )

    func open() {
        let waiters = state.withLock { state in
            state.opened = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let opened = state.withLock { state in
                if !state.opened { state.waiters.append(continuation) }
                return state.opened
            }
            arrivals.increment()
            if opened { continuation.resume() }
        }
    }
}

// @unchecked is safe: currentInstant, sleepers and cancelledIDs are only touched under `lock`; `parked` locks itself.
final class TestClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol, Hashable {
        var offset: Swift.Duration

        func advanced(by duration: Swift.Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Swift.Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    typealias Duration = Swift.Duration

    private struct Sleeper {
        let id: UUID
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var currentInstant = Instant(offset: .zero)
    private var sleepers: [Sleeper] = [] {
        didSet {
            let count = sleepers.count
            parked.update { $0 = count }
        }
    }
    private var cancelledIDs: Set<UUID> = []
    private let parked = Awaitable(0)

    var now: Instant {
        lock.lock()
        defer { lock.unlock() }
        return currentInstant
    }

    var minimumResolution: Swift.Duration { .zero }

    var sleeperCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sleepers.count
    }

    /// Returns once `count` sleepers are parked, so an `advance` after it is sure to reach them.
    @discardableResult
    func waitForSleeper(
        count: Int = 1,
        timeout: Swift.Duration = .seconds(30),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        await parked.wait(
            atLeast: count, "\(count) sleeper(s) on the test clock", timeout: timeout, sourceLocation: sourceLocation
        )
    }

    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if cancelledIDs.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if deadline <= currentInstant {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            if let index = sleepers.firstIndex(where: { $0.id == id }) {
                let sleeper = sleepers.remove(at: index)
                lock.unlock()
                sleeper.continuation.resume(throwing: CancellationError())
            } else {
                cancelledIDs.insert(id)
                lock.unlock()
            }
        }
    }

    func advance(by duration: Swift.Duration) {
        lock.lock()
        currentInstant = currentInstant.advanced(by: duration)
        let now = currentInstant
        var due: [Sleeper] = []
        sleepers.removeAll { sleeper in
            guard sleeper.deadline <= now else { return false }
            due.append(sleeper)
            return true
        }
        lock.unlock()
        for sleeper in due { sleeper.continuation.resume() }
    }
}
