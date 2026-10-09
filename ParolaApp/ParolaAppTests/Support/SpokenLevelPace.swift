import Foundation
import ParolaCore

/// A level that climbs a few percent with every sample the take keeps, so each sample reads differently.
@MainActor
func climbingLevels(on meter: LevelMeter) -> Task<Void, Never> {
    Task { @MainActor in
        var step = 0
        while !Task.isCancelled {
            meter.record(0.3 + 0.6 * Float(step % 400) / 400)
            step += 1
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// How many times `read` gave something new over `duration`, polled every few milliseconds.
@MainActor
func changes(of read: @MainActor () -> String?, over duration: Duration) async -> Int {
    let deadline = ContinuousClock.now + duration
    var last = read()
    var count = 0
    while ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
        let now = read()
        if now != last {
            count += 1
            last = now
        }
    }
    return count
}
