#if os(macOS)
import Foundation

/// Downloads the audio behind a link to a local file, reporting how it's getting on.
public protocol MediaFetcher: Sendable {
    func fetch(url: URL, progress: @escaping @Sendable (LinkFetchEvent) -> Void) async throws -> FetchedMedia
}

public enum MediaFetcherFactory {
    public static func make() -> any MediaFetcher {
        if let failure = MockMediaFetcherRegistry.shared.resolveFailure() {
            return MockMediaFetcher(failure: failure)
        }
        if let url = MockMediaFetcherRegistry.shared.resolve() {
            return MockMediaFetcher(fixtureURL: url)
        }
        return YouTubeMediaFetcher()
    }
}

#endif
