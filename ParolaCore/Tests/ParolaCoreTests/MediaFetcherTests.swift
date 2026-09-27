#if os(macOS)
import Foundation
import Testing
@testable import ParolaCore

@Suite("MediaFetcher")
struct MediaFetcherTests {
    let fixtureA = URL(fileURLWithPath: "/tmp/a.m4a")
    let fixtureB = URL(fileURLWithPath: "/tmp/b.m4a")

    @Test("MockMediaFetcher returns fixture regardless of input URL")
    func mockIgnoresInputURL() async throws {
        let fetcher = MockMediaFetcher(fixtureURL: fixtureA)
        let result = try await fetcher.fetch(url: fixtureB) { _ in }
        #expect(result.fileURL == fixtureA)
    }

    @Test("MockMediaFetcherRegistry install, resolve, clear round-trip")
    func registryRoundTrip() {
        let reg = MockMediaFetcherRegistry()
        #expect(reg.resolve() == nil)
        reg.install(fixtureA)
        #expect(reg.resolve() == fixtureA)
        reg.clear()
        #expect(reg.resolve() == nil)
    }

    @Test("MediaFetcherFactory returns MockMediaFetcher when fixture installed, YouTubeMediaFetcher otherwise")
    func factorySelectsBackend() async throws {
        MockMediaFetcherRegistry.shared.clear()
        let real = MediaFetcherFactory.make()
        #expect(real is YouTubeMediaFetcher)

        MockMediaFetcherRegistry.shared.install(fixtureA)
        let mock = MediaFetcherFactory.make()
        #expect(mock is MockMediaFetcher)

        MockMediaFetcherRegistry.shared.clear()
    }

    @Test("a canned link failure is what the mock fetcher throws, and clear drops it")
    func cannedFailure() async throws {
        let reg = MockMediaFetcherRegistry()
        let failure = LinkDownloadFailure(reason: .refused(httpStatus: 403), site: "YouTube")
        reg.installFailure(failure)
        #expect(reg.resolveFailure() == failure)

        do {
            _ = try await MockMediaFetcher(failure: failure).fetch(url: fixtureB) { _ in }
            Issue.record("expected the canned failure")
        } catch ParolaError.linkDownloadFailed(let thrown) {
            #expect(thrown == failure)
        }

        reg.clear()
        #expect(reg.resolveFailure() == nil)
    }
}

#endif
