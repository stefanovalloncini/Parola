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
        let result = try await fetcher.prepare(url: fixtureB)
        #expect(result == fixtureA)
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
}

#endif
