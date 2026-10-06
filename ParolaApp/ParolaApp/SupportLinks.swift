import Foundation

/// Single source of truth for Parola's outbound links. Centralized so making the repo public is a one-line change.
enum SupportLinks {
    static let repository = URL(string: "https://github.com/stefanovalloncini/Parola")!
    static let releases = repository.appending(path: "releases")
    static let ytDlpReleases = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest")!
    static let homebrew = URL(string: "https://brew.sh")!
    static let feedbackEmail = "stefano.valloncini@gmail.com"

    static var feedbackMailto: URL? {
        URL(string: "mailto:\(feedbackEmail)?subject=Parola%20feedback")
    }
}
