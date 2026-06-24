import Foundation
import Testing
@testable import Parola

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
