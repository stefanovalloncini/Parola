import Foundation
import Testing

/// Polls a condition on the main actor until it holds. On timeout it records an Issue naming the
/// wait, so a condition that never lands fails where it was awaited instead of somewhere later.
@MainActor
@discardableResult
func waitUntil(
    timeoutMs: Int = 5_000,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @MainActor () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    if await condition() { return true }
    Issue.record("waited \(timeoutMs) ms and the condition never held", sourceLocation: sourceLocation)
    return false
}

/// Gives a fire-and-forget hop a fixed window to land before a negative assertion reads the result.
/// An explicit duration, not an iteration count: there is no condition to wait for.
@MainActor
func settle(for duration: Duration = .milliseconds(200)) async {
    try? await Task.sleep(for: duration)
}
