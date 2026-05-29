#if os(macOS)
import Foundation
import os

public final class MockMediaFetcher: MediaFetcher {
    private let fixtureURL: URL

    public init(fixtureURL: URL) {
        self.fixtureURL = fixtureURL
    }

    public func prepare(url: URL) async throws -> URL {
        fixtureURL
    }
}

public final class MockMediaFetcherRegistry: Sendable {
    public static let shared = MockMediaFetcherRegistry()
    private let state = OSAllocatedUnfairLock<URL?>(initialState: nil)
    public init() {}
    public func install(_ url: URL) { state.withLock { $0 = url } }
    public func clear() { state.withLock { $0 = nil } }
    public func resolve() -> URL? { state.withLock { $0 } }
}

#endif
