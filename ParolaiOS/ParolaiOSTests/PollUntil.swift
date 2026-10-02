import Testing

/// For state nothing announces: re-checks `condition` every 20 ms until it's true or `timeout` passes.
@MainActor
func pollUntil(
    timeout: Duration = .seconds(10),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    let met = condition()
    #expect(met, "gave up after \(timeout) waiting for the condition", sourceLocation: sourceLocation)
}
