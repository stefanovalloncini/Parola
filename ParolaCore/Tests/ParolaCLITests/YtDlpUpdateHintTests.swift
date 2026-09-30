import Foundation
import Testing
import ParolaCore
@testable import parola

@Suite("yt-dlp update hint on a failed link")
struct YtDlpUpdateHintTests {
    private let stale = LinkDownloadFailure(reason: .refused(httpStatus: 403), site: "YouTube", ytDlpIsStale: true)

    private func linkFailure(in error: any Error) -> LinkDownloadFailure? {
        guard case .linkDownloadFailed(let failure)? = error as? ParolaError else { return nil }
        return failure
    }

    @Test("a stale yt-dlp failure ends with the command that updates it")
    func staleFailureGetsTheCommand() throws {
        let hinted = addingYtDlpUpdateHint(to: ParolaError.linkDownloadFailed(stale)) {
            .homebrew(brewPath: "/opt/homebrew/bin/brew")
        }

        let failure = try #require(hinted as? StaleYtDlpFailure)
        #expect(failure.description == "\(stale.message)\nTo update yt-dlp, run: /opt/homebrew/bin/brew upgrade yt-dlp")
        #expect(failure.errorDescription == failure.description)
    }

    @Test("a fresh yt-dlp failure is passed through untouched")
    func freshFailurePassesThrough() {
        var fresh = stale
        fresh.ytDlpIsStale = false
        let hinted = addingYtDlpUpdateHint(to: ParolaError.linkDownloadFailed(fresh)) {
            Issue.record("a fresh failure should not look up the route")
            return .manual
        }

        #expect(linkFailure(in: hinted) == fresh)
    }

    @Test("a stale failure with no command to offer is passed through untouched")
    func manualRoutePassesThrough() {
        let hinted = addingYtDlpUpdateHint(to: ParolaError.linkDownloadFailed(stale)) { .manual }
        #expect(linkFailure(in: hinted) == stale)
    }

    @Test("a failure with yt-dlp nowhere on disk is passed through untouched")
    func missingToolPassesThrough() {
        let hinted = addingYtDlpUpdateHint(to: ParolaError.linkDownloadFailed(stale)) { nil }
        #expect(linkFailure(in: hinted) == stale)
    }

    @Test("an error other than a link failure is passed through untouched")
    func otherErrorsPassThrough() {
        let hinted = addingYtDlpUpdateHint(to: CancellationError()) { .command("pipx upgrade yt-dlp") }
        #expect(hinted is CancellationError)
    }
}
