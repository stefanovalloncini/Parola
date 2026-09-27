#if os(macOS)
import Foundation

public final class YouTubeMediaFetcher: MediaFetcher {
    public init() {}

    public func fetch(url: URL, progress: @escaping @Sendable (LinkFetchEvent) -> Void) async throws -> FetchedMedia {
        try await YouTubeAudioSource(url: url).fetch(progress: progress)
    }
}

#endif
