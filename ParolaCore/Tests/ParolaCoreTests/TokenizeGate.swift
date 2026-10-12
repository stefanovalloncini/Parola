import Foundation
import os

final class TokenizeGate: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (armed: false, entered: 0))
    private let release = DispatchSemaphore(value: 0)

    var entered: Int { state.withLock { $0.entered } }

    func arm() { state.withLock { $0.armed = true } }

    func open() { release.signal() }

    func hook() {
        let hold = state.withLock { state -> Bool in
            guard state.armed else { return false }
            state.armed = false
            state.entered += 1
            return true
        }
        if hold { _ = release.wait(timeout: .now() + 30) }
    }
}
