import os

/// Passes a download's progress on once per whole percent, never going backwards.
package enum DownloadProgressGate {
    private struct State {
        var highest = 0.0
        var percent = -1
    }

    package static func gating(_ report: @escaping @Sendable (Double) -> Void) -> @Sendable (Double) -> Void {
        let state = OSAllocatedUnfairLock(initialState: State())
        return { fraction in
            let reading = state.withLock { state -> Double? in
                state.highest = max(state.highest, min(max(fraction, 0), 1))
                let percent = Int(state.highest * 100)
                guard percent != state.percent else { return nil }
                state.percent = percent
                return state.highest
            }
            if let reading { report(reading) }
        }
    }
}
