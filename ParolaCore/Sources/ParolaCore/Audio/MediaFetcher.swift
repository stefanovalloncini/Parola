#if os(macOS)
import Foundation

/// Downloads or resolves audio from a remote media URL and returns a local file URL.
public protocol MediaFetcher: Sendable {
    func prepare(url: URL) async throws -> URL
}

public enum MediaFetcherFactory {
    public static func make() -> any MediaFetcher {
        if let url = MockMediaFetcherRegistry.shared.resolve() {
            return MockMediaFetcher(fixtureURL: url)
        }
        return YouTubeMediaFetcher()
    }
}

#endif
