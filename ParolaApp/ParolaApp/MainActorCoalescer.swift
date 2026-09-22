import Foundation
import os

/// Keep-newest, single flight: a burst of engine callbacks costs one main-actor hop, not one each.
final class MainActorCoalescer<Value: Sendable>: Sendable {
    private struct Slot {
        var pending: Value?
        var hopScheduled = false
        var hops = 0
    }

    private let slot = OSAllocatedUnfairLock(initialState: Slot())
    private let deliver: @MainActor @Sendable (Value) -> Void

    init(deliver: @escaping @MainActor @Sendable (Value) -> Void) {
        self.deliver = deliver
    }

    var hopCount: Int { slot.withLock { $0.hops } }

    func send(_ value: Value) {
        let schedule = slot.withLock { state -> Bool in
            state.pending = value
            guard !state.hopScheduled else { return false }
            state.hopScheduled = true
            return true
        }
        guard schedule else { return }
        Task { @MainActor in self.drain() }
    }

    @MainActor private func drain() {
        let value = slot.withLock { state -> Value? in
            state.hops += 1
            state.hopScheduled = false
            let pending = state.pending
            state.pending = nil
            return pending
        }
        guard let value else { return }
        deliver(value)
    }
}
