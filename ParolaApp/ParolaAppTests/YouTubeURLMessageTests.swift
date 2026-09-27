import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@Suite("Unsupported URL message")
struct YouTubeURLMessageTests {
    private func italianBundle() throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test("an unsupported media URL surfaces the Italian message")
    func localizesUnsupportedURL() throws {
        let message = AppModel.unsupportedURLMessage(bundle: try italianBundle())
        #expect(message == "Questo URL non proviene da una sorgente supportata da yt-dlp.")
    }
}

extension TranscriberMockSuites {
    @MainActor
    @Suite("YouTube task lifecycle")
    struct YouTubeTaskLifecycleTests {
        private func makeModel() -> AppModel {
            AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("yt"))
        }

        @Test("cancelled task leaves the replacement's handle intact")
        func restartKeepsHandle() async {
            let model = makeModel()
            model.linkFetcher = FixtureLinkFetcher(fixtureURL: URL(fileURLWithPath: "/tmp/missing-\(UUID()).wav"))
            model.transcribeYouTube(urlString: "https://www.youtube.com/watch?v=aaaaaaaaaaa")
            model.cancelCurrentWork()
            model.transcribeYouTube(urlString: "https://www.youtube.com/watch?v=bbbbbbbbbbb")
            for _ in 0..<8 { await Task.yield() }
            #expect(model.canCancel)
        }
    }
}
