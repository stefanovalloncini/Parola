import Foundation
import Testing
@testable import ParolaCore

@Suite("YouTube URL detection")
struct YouTubeURLTests {
    @Test("classic watch URL")
    func watch() {
        let url = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
        #expect(url.isYouTubeVideo)
    }

    @Test("youtu.be short URL")
    func youtuBe() {
        let url = URL(string: "https://youtu.be/dQw4w9WgXcQ")!
        #expect(url.isYouTubeVideo)
    }

    @Test("mobile m.youtube.com")
    func mobile() {
        let url = URL(string: "https://m.youtube.com/watch?v=abc")!
        #expect(url.isYouTubeVideo)
    }

    @Test("YouTube shorts")
    func shorts() {
        let url = URL(string: "https://www.youtube.com/shorts/abc123")!
        #expect(url.isYouTubeVideo)
    }

    @Test("YouTube music")
    func music() {
        let url = URL(string: "https://music.youtube.com/watch?v=abc")!
        #expect(url.isYouTubeVideo)
    }

    @Test("youtube.com homepage is not a video")
    func homepage() {
        let url = URL(string: "https://www.youtube.com/")!
        #expect(url.isYouTubeVideo == false)
    }

    @Test("vimeo is not YouTube")
    func vimeo() {
        let url = URL(string: "https://vimeo.com/12345")!
        #expect(url.isYouTubeVideo == false)
    }

    @Test("file URL is not YouTube")
    func fileURL() {
        let url = URL(fileURLWithPath: "/tmp/x.mp4")
        #expect(url.isYouTubeVideo == false)
    }

    @Test("yt-dlp accepts youtube")
    func ytDlpYouTube() {
        #expect(URL(string: "https://www.youtube.com/watch?v=abc")!.isYtDlpSupported)
    }

    @Test("yt-dlp accepts vimeo, x, tiktok, soundcloud")
    func ytDlpOthers() {
        #expect(URL(string: "https://vimeo.com/12345")!.isYtDlpSupported)
        #expect(URL(string: "https://x.com/user/status/9")!.isYtDlpSupported)
        #expect(URL(string: "https://twitter.com/user/status/9")!.isYtDlpSupported)
        #expect(URL(string: "https://www.tiktok.com/@u/video/9")!.isYtDlpSupported)
        #expect(URL(string: "https://soundcloud.com/u/track")!.isYtDlpSupported)
        #expect(URL(string: "https://www.facebook.com/u/videos/9")!.isYtDlpSupported)
    }

    @Test("yt-dlp rejects file and arbitrary URLs")
    func ytDlpRejects() {
        #expect(URL(fileURLWithPath: "/tmp/x.mp4").isYtDlpSupported == false)
        #expect(URL(string: "https://example.com/audio.mp3")!.isYtDlpSupported == false)
    }
}
