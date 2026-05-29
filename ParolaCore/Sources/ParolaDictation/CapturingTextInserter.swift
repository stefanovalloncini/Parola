import os

public final class CapturedInsertionStore: Sendable {
    public static let shared = CapturedInsertionStore()
    private let state = OSAllocatedUnfairLock<[String]>(initialState: [])

    public init() {}

    public func record(_ text: String) { state.withLock { $0.append(text) } }
    public func last() -> String? { state.withLock { $0.last } }
    public func all() -> [String] { state.withLock { $0 } }
    public func clear() { state.withLock { $0 = [] } }
}

public struct CapturingTextInserter: TextInserter {
    private let store: CapturedInsertionStore

    public init(store: CapturedInsertionStore = .shared) {
        self.store = store
    }

    public func insert(_ text: String) async {
        store.record(text)
    }
}
