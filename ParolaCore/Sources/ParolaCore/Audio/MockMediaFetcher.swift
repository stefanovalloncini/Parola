#if os(macOS)
import Foundation
import os

public final class MockMediaFetcher: MediaFetcher {
    private let outcome: Result<URL, ParolaError>

    public init(fixtureURL: URL) {
        outcome = .success(fixtureURL)
    }

    public init(failure: LinkDownloadFailure) {
        outcome = .failure(.linkDownloadFailed(failure))
    }

    public func fetch(url: URL, progress: @escaping @Sendable (LinkFetchEvent) -> Void) async throws -> FetchedMedia {
        FetchedMedia(fileURL: try outcome.get())
    }
}

public final class MockMediaFetcherRegistry: Sendable {
    public static let shared = MockMediaFetcherRegistry()
    private let state = OSAllocatedUnfairLock<URL?>(initialState: nil)
    private let failure = OSAllocatedUnfairLock<LinkDownloadFailure?>(initialState: nil)
    public init() {}
    public func install(_ url: URL) { state.withLock { $0 = url } }
    public func installFailure(_ failure: LinkDownloadFailure) { self.failure.withLock { $0 = failure } }
    public func clear() {
        state.withLock { $0 = nil }
        failure.withLock { $0 = nil }
    }
    public func resolve() -> URL? { state.withLock { $0 } }
    public func resolveFailure() -> LinkDownloadFailure? { failure.withLock { $0 } }
}

#endif
