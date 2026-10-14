import Foundation
import os

public final class MockStreamingTranscriberRegistry: Sendable {
    public static let shared = MockStreamingTranscriberRegistry()
    private struct State {
        var response: MockTranscriberResponse?
        var sources: [CaptionSource] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    public init() {}
    public func install(_ response: MockTranscriberResponse) {
        state.withLock {
            $0.response = response
            $0.sources = []
        }
    }
    public func clear() {
        state.withLock {
            $0.response = nil
            $0.sources = []
        }
    }
    public func resolve() -> MockTranscriberResponse? { state.withLock { $0.response } }

    /// The source each mock transcriber was made with since the response was installed, oldest first.
    public func madeSources() -> [CaptionSource] { state.withLock { $0.sources } }

    func recordMade(source: CaptionSource) { state.withLock { $0.sources.append(source) } }
}
