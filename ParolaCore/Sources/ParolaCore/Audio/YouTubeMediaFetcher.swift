#if os(macOS)
import Foundation

public final class YouTubeMediaFetcher: MediaFetcher {
    public init() {}

    public func prepare(url: URL) async throws -> URL {
        let source = try YouTubeAudioSource(url: url)
        return try await source.prepare()
    }
}

#endif
