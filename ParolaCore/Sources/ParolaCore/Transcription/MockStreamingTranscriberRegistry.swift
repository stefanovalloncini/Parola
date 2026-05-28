import Foundation
import os

public final class MockStreamingTranscriberRegistry: Sendable {
    public static let shared = MockStreamingTranscriberRegistry()
    private let state = OSAllocatedUnfairLock<MockTranscriberResponse?>(initialState: nil)
    public init() {}
    public func install(_ response: MockTranscriberResponse) { state.withLock { $0 = response } }
    public func clear() { state.withLock { $0 = nil } }
    public func resolve() -> MockTranscriberResponse? { state.withLock { $0 } }
}
