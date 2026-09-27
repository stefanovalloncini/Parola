#if os(macOS)
import Foundation

/// Fetches what a link points at: its audio for transcribing, or the captions it already has.
public protocol LinkFetcher: Sendable {
    func fetchAudio(url: URL, progress: @escaping @Sendable (LinkFetchEvent) -> Void) async throws -> FetchedMedia
    func fetchCaptions(url: URL, language: String?) async throws -> FetchedCaptions
}

/// The fetcher behind every link: yt-dlp, found where Homebrew or `$PATH` put it.
public struct YtDlpLinkFetcher: LinkFetcher {
    private let features: FeatureSet

    public init(features: FeatureSet = .resolve()) {
        self.features = features
    }

    public func fetchAudio(url: URL, progress: @escaping @Sendable (LinkFetchEvent) -> Void) async throws -> FetchedMedia {
        try await YouTubeAudioSource(url: url, features: features).fetch(progress: progress)
    }

    public func fetchCaptions(url: URL, language: String?) async throws -> FetchedCaptions {
        try features.require(.youtube)
        return try await YouTubeSubsFetcher.fetchWithTitle(url: url, preferLanguage: language)
    }
}

/// Answers every link with a local file it doesn't own, or with one failure; for tests and the bridge.
public struct FixtureLinkFetcher: LinkFetcher {
    private let outcome: Result<URL, ParolaError>

    public init(fixtureURL: URL) {
        outcome = .success(fixtureURL)
    }

    public init(failure: LinkDownloadFailure) {
        outcome = .failure(.linkDownloadFailed(failure))
    }

    public func fetchAudio(url: URL, progress: @escaping @Sendable (LinkFetchEvent) -> Void) async throws -> FetchedMedia {
        FetchedMedia(fileURL: try outcome.get())
    }

    public func fetchCaptions(url: URL, language: String?) async throws -> FetchedCaptions {
        _ = try outcome.get()
        throw ParolaError.linkDownloadFailed(LinkDownloadFailure(reason: .noCaptions, site: LinkDownloadFailure.site(for: url)))
    }
}
#endif
