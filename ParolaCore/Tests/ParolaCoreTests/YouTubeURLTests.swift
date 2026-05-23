import Foundation
import Testing
@testable import ParolaCore

@Suite("YouTube URL detection")
struct YouTubeURLTests {
    @Test(
        "classifies isYouTubeVideo",
        arguments: [
            (name: "classic watch URL", url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", isYouTube: true),
            (name: "youtu.be short URL", url: "https://youtu.be/dQw4w9WgXcQ", isYouTube: true),
            (name: "mobile m.youtube.com", url: "https://m.youtube.com/watch?v=abc", isYouTube: true),
            (name: "YouTube shorts", url: "https://www.youtube.com/shorts/abc123", isYouTube: true),
            (name: "YouTube music", url: "https://music.youtube.com/watch?v=abc", isYouTube: true),
            (name: "youtube.com homepage", url: "https://www.youtube.com/", isYouTube: false),
            (name: "vimeo", url: "https://vimeo.com/12345", isYouTube: false),
        ]
    )
    func isYouTubeVideo(name: String, url: String, isYouTube: Bool) throws {
        let parsed = try #require(URL(string: url))
        #expect(parsed.isYouTubeVideo == isYouTube)
    }

    @Test("file URL is not YouTube")
    func fileURLIsNotYouTube() {
        let url = URL(fileURLWithPath: "/tmp/x.mp4")
        #expect(url.isYouTubeVideo == false)
    }

    @Test(
        "classifies isYtDlpSupported",
        arguments: [
            (name: "youtube", url: "https://www.youtube.com/watch?v=abc", supported: true),
            (name: "vimeo", url: "https://vimeo.com/12345", supported: true),
            (name: "x", url: "https://x.com/user/status/9", supported: true),
            (name: "twitter", url: "https://twitter.com/user/status/9", supported: true),
            (name: "tiktok", url: "https://www.tiktok.com/@u/video/9", supported: true),
            (name: "soundcloud", url: "https://soundcloud.com/u/track", supported: true),
            (name: "facebook", url: "https://www.facebook.com/u/videos/9", supported: true),
            (name: "arbitrary URL", url: "https://example.com/audio.mp3", supported: false),
        ]
    )
    func isYtDlpSupported(name: String, url: String, supported: Bool) throws {
        let parsed = try #require(URL(string: url))
        #expect(parsed.isYtDlpSupported == supported)
    }

    @Test("yt-dlp rejects file URLs")
    func ytDlpRejectsFileURL() {
        #expect(URL(fileURLWithPath: "/tmp/x.mp4").isYtDlpSupported == false)
    }
}
