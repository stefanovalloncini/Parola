import Testing
import ParolaCore

/// Load-bearing: the mock registries are process-global and tests here assume theirs stays put across awaits.
@Suite(.serialized)
struct TranscriberMockSuites {}

struct MockRegistries: OptionSet {
    let rawValue: Int

    static let transcriber = MockRegistries(rawValue: 1 << 0)
    static let audioSource = MockRegistries(rawValue: 1 << 1)
    static let streaming = MockRegistries(rawValue: 1 << 3)
    static let all: MockRegistries = [.transcriber, .audioSource, .streaming]
}

/// Awaited teardown on every exit: a fire-and-forget clear can land after the next test installed its mock.
@MainActor
func withMocksCleared(_ registries: MockRegistries, _ body: @MainActor () async throws -> Void) async throws {
    do {
        try await body()
    } catch {
        await clearMocks(registries)
        throw error
    }
    await clearMocks(registries)
}

private func clearMocks(_ registries: MockRegistries) async {
    if registries.contains(.transcriber) { await MockTranscriberRegistry.shared.clear() }
    if registries.contains(.audioSource) { await MockAudioSourceRegistry.shared.clear() }
    if registries.contains(.streaming) { MockStreamingTranscriberRegistry.shared.clear() }
}
