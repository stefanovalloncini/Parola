import Foundation

package enum ModelResidency {
    package static let idleTimeout: Duration = .seconds(600)
}

/// One pending idle unload; the owner checks a fire's epoch with `isCurrent`, as a fire can land after a later arm or disarm.
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
