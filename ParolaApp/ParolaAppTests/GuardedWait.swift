import Foundation
import Testing
import os

/// Awaits work the product started; on cancellation or at `timeout` it records an issue and returns nil instead of hanging the run.
@MainActor
@discardableResult
func awaitGuarded<Success: Sendable, Failure: Error>(
    _ description: String,
    timeout: Duration = .seconds(30),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ operation: @escaping @MainActor @Sendable () async throws(Failure) -> Success
) async throws(Failure) -> Success? {
    let race = OneShot<Result<Success, Failure>>()
    let work = Task { @MainActor in
        do throws(Failure) {
            race.settle(.finished(.success(try await operation())))
        } catch {
            race.settle(.finished(.failure(error)))
        }
    }
    let timer = Task {
        try? await Task.sleep(for: timeout)
        guard !Task.isCancelled else { return }
        race.settle(.timedOut)
    }
    defer { timer.cancel() }
    let outcome = await withTaskCancellationHandler {
        await race.outcome()
    } onCancel: {
        race.settle(.cancelled)
    }
    switch outcome {
    case .finished(let result):
        return try result.get()
    case .timedOut:
        work.cancel()
        Issue.record("gave up after \(timeout) waiting for \(description)", sourceLocation: sourceLocation)
        return nil
    case .cancelled:
        work.cancel()
        Issue.record("cancelled while waiting for \(description)", sourceLocation: sourceLocation)
        return nil
    }
}

/// For state nothing announces: re-checks it every 10 ms under the same guards as `awaitGuarded`.
@MainActor
@discardableResult
func pollUntil(
    _ description: String,
    timeout: Duration = .seconds(30),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @MainActor () async -> Bool
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

/// The first `settle` wins; a waiter that arrives after it returns at once.
private final class OneShot<Value: Sendable>: Sendable {
    enum Outcome: Sendable {
        case finished(Value)
        case timedOut
        case cancelled
    }

    private struct State: Sendable {
        var outcome: Outcome?
        var waiter: CheckedContinuation<Outcome, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func settle(_ outcome: Outcome) {
        let waiter = state.withLock { state -> CheckedContinuation<Outcome, Never>? in
            guard state.outcome == nil else { return nil }
            state.outcome = outcome
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: outcome)
    }

    func outcome() async -> Outcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            let settled = state.withLock { state -> Outcome? in
                if let outcome = state.outcome { return outcome }
                state.waiter = continuation
                return nil
            }
            if let settled { continuation.resume(returning: settled) }
        }
    }
}
