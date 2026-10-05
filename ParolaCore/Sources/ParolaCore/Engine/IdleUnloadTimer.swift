import Foundation

package enum ModelResidency {
    package static let idleTimeout: Duration = .seconds(600)
}

/// One pending idle unload for an actor that owns a model. A fire hands back the epoch it was
/// armed under; the owner checks `isCurrent` before unloading, since a fire can slip past its
/// cancel and land after a later arm or disarm.
package struct IdleUnloadTimer {
    private var epoch = 0
    private var task: Task<Void, Never>?

    package init() {}

    package mutating func arm(
        after delay: Duration,
        clock: any Clock<Duration>,
        fire: @escaping @Sendable (_ epoch: Int) async -> Void
    ) {
        disarm()
        let armedEpoch = epoch
        task = Task {
            try? await Task.sleep(for: delay, clock: clock)
            if Task.isCancelled { return }
            await fire(armedEpoch)
        }
    }

    package mutating func disarm() {
        task?.cancel()
        task = nil
        epoch &+= 1
    }

    package func isCurrent(_ epoch: Int) -> Bool {
        epoch == self.epoch
    }
}
