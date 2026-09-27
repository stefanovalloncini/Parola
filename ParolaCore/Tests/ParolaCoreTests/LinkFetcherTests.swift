#if os(macOS)
import Foundation
import Testing
@testable import ParolaCore

@Suite("LinkFetcher")
struct LinkFetcherTests {
    let fixtureA = URL(fileURLWithPath: "/tmp/a.m4a")
    let link = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!

    @Test("a fixture fetcher answers every link with its file, and never owns it")
    func fixtureIgnoresTheLink() async throws {
        let media = try await FixtureLinkFetcher(fixtureURL: fixtureA).fetchAudio(url: link) { _ in }

        #expect(media.fileURL == fixtureA)
        #expect(media.workingDirectory == nil)
    }

    @Test("a canned link failure is what the fixture fetcher throws")
    func cannedFailure() async throws {
        let failure = LinkDownloadFailure(reason: .refused(httpStatus: 403), site: "YouTube")

        do {
            _ = try await FixtureLinkFetcher(failure: failure).fetchAudio(url: link) { _ in }
            Issue.record("expected the canned failure")
        } catch ParolaError.linkDownloadFailed(let thrown) {
            #expect(thrown == failure)
        }
    }

    @Test("the yt-dlp fetcher refuses both kinds of fetch with YouTube turned off")
    func ytDlpFetcherHonoursTheFeature() async {
        let fetcher = YtDlpLinkFetcher(features: FeatureSet(enabled: []))

        await #expect(throws: ParolaError.self) { _ = try await fetcher.fetchAudio(url: link) { _ in } }
        await #expect(throws: ParolaError.self) { _ = try await fetcher.fetchCaptions(url: link, language: nil) }
    }
}
#endif
