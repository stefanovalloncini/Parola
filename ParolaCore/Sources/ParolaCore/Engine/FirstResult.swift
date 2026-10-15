import Foundation
import os

/// Settles on the first value anyone gives it; later values are ignored, so racers never have to await each other.
final class FirstResult<Value: Sendable>: Sendable {
    private struct State {
        var value: Value?
        var waiter: CheckedContinuation<Value, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func resolve(_ value: Value) {
        let waiter = state.withLock { state -> CheckedContinuation<Value, Never>? in
            guard state.value == nil else { return nil }
            state.value = value
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: value)
    }

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            let settled = state.withLock { state -> Value? in
                if state.value == nil { state.waiter = continuation }
                return state.value
            }
            if let settled { continuation.resume(returning: settled) }
        }
    }
}
