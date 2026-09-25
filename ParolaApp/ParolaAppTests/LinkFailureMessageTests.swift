import Foundation
import Testing
@testable import Parola
import ParolaCore

@Suite("Link failure message")
struct LinkFailureMessageTests {
    private func italianBundle() throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    private static let refused403 = """
        WARNING: Your yt-dlp version (2026.03.17) is older than 90 days!
                 It is strongly recommended to always use the latest version.
                 You installed yt-dlp with pip or using the wheel from PyPi; Use that to update.
                 To suppress this warning, add --no-update to your command/config.
        ERROR: unable to download video data: HTTP Error 403: Forbidden
        """

    private static let september23: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 18))!
    }()

    private static let staleRefusal = LinkDownloadFailure(
        exitStatus: 1, stderr: refused403, stdout: "", installedVersion: "2026.03.17\n", site: "YouTube", now: september23
    )

    private static let everyReason: [LinkDownloadFailure] = [
        LinkDownloadFailure(reason: .refused(httpStatus: 403), site: "YouTube"),
        LinkDownloadFailure(reason: .refused(httpStatus: nil), site: "YouTube"),
        LinkDownloadFailure(reason: .refused(httpStatus: 429)),
        LinkDownloadFailure(reason: .refused(httpStatus: nil)),
        LinkDownloadFailure(reason: .unavailable(.removed), site: "YouTube"),
        LinkDownloadFailure(reason: .unavailable(.privateVideo), site: "YouTube"),
        LinkDownloadFailure(reason: .unavailable(.membersOnly), site: "YouTube"),
        LinkDownloadFailure(reason: .unavailable(.ageRestricted), site: "YouTube"),
        LinkDownloadFailure(reason: .unavailable(.regionLocked), site: "YouTube"),
        LinkDownloadFailure(reason: .unreachable, site: "vimeo.com"),
        LinkDownloadFailure(reason: .unreachable),
        LinkDownloadFailure(reason: .timedOut(seconds: 120), site: "YouTube"),
        LinkDownloadFailure(reason: .noCaptions, site: "YouTube"),
        LinkDownloadFailure(reason: .noAudio, site: "YouTube"),
        LinkDownloadFailure(reason: .unsupportedLink),
        LinkDownloadFailure(reason: .toolFailedToStart, site: "YouTube"),
        LinkDownloadFailure(reason: .toolError("Unable to extract uploader id."), site: "YouTube"),
        LinkDownloadFailure(reason: .toolExited(status: 9), site: "YouTube"),
        LinkDownloadFailure(reason: .timedOut(seconds: 120), site: "YouTube", ytDlpIsStale: true),
        staleRefusal,
    ]

    @Test("the 403 from an old yt-dlp reads plainly on the banner")
    func staleRefusalReadsPlainly() {
        let message = AppModel.transcriptionFailureMessage(for: ParolaError.linkDownloadFailed(Self.staleRefusal))

        #expect(message == "YouTube refused the download (HTTP 403). Your yt-dlp (2026.03.17) is out of date — update it and try again.")
        #expect(!message.contains("WARNING"))
        #expect(!message.contains("pip"))
        #expect(!message.contains("Audio capture unavailable"))
    }

    @Test("the same failure reads in Italian")
    func staleRefusalInItalian() throws {
        let message = AppModel.transcriptionFailureMessage(
            for: ParolaError.linkDownloadFailed(Self.staleRefusal), bundle: try italianBundle()
        )

        #expect(message == "YouTube ha rifiutato il download (HTTP 403). La tua versione di yt-dlp (2026.03.17) non è aggiornata: aggiornala e riprova.")
    }

    @Test("the English banner says what the CLI says", arguments: everyReason)
    func englishMatchesTheCLI(failure: LinkDownloadFailure) {
        #expect(AppModel.linkFailureMessage(failure) == failure.message)
    }

    @Test("a missing yt-dlp points at Settings instead of a Terminal command")
    func missingToolPointsAtSettings() {
        let message = AppModel.linkFailureMessage(LinkDownloadFailure(reason: .toolMissing, site: "YouTube"))

        #expect(message == "yt-dlp isn't installed. Install it in Settings › Integrations.")
    }

    @Test("every reason has Italian copy", arguments: everyReason + [LinkDownloadFailure(reason: .toolMissing)])
    func everyReasonInItalian(failure: LinkDownloadFailure) throws {
        let italian = AppModel.linkFailureMessage(failure, bundle: try italianBundle())

        #expect(italian != AppModel.linkFailureMessage(failure))
        #expect(!italian.isEmpty)
    }
}
