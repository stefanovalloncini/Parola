import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

private let staleRefusal = LinkDownloadFailure(
    reason: .refused(httpStatus: 403), site: "YouTube", ytDlpVersion: YtDlpVersion("2026.03.17"), ytDlpIsStale: true
)

private let staleRefusalMessage =
    "YouTube refused the download (HTTP 403). Your yt-dlp (2026.03.17) is out of date — update it and try again."

private func fakeTool(_ body: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("parola-fake-tool-\(UUID().uuidString)")
    try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

@Suite("yt-dlp update offer")
struct YtDlpUpdateOfferTests {
    private static let september23: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 18))!
    }()

    private func offer(
        _ failure: LinkDownloadFailure?,
        route: YtDlpInstaller.UpdateRoute? = .homebrew(brewPath: "/opt/homebrew/bin/brew"),
        installed: String? = "2026.03.17",
        updating: Bool = false
    ) -> AppModel.YtDlpUpdateOffer {
        AppModel.ytDlpUpdateOffer(
            for: failure, route: route, installed: installed.flatMap(YtDlpVersion.init), updating: updating, now: Self.september23
        )
    }

    @Test("a stale failure offers the update that fits the install")
    func staleFailureOffersAnUpdate() {
        #expect(offer(staleRefusal) == .update)
        #expect(offer(staleRefusal, installed: nil) == .update)
        #expect(offer(staleRefusal, updating: true) == .updating)
        #expect(offer(staleRefusal, route: .command("/usr/local/bin/yt-dlp -U")) == .command("/usr/local/bin/yt-dlp -U"))
        #expect(offer(staleRefusal, route: .manual) == .manual)
        #expect(offer(staleRefusal, installed: "2026.09.20") == .updated("2026.09.20"))
    }

    @Test("nothing is offered when yt-dlp isn't the problem or can't be found")
    func noOffer() {
        #expect(offer(nil) == .none)
        #expect(offer(LinkDownloadFailure(reason: .refused(httpStatus: 403), site: "YouTube")) == .none)
        #expect(offer(staleRefusal, route: nil) == .none)
    }
}

extension TranscriberMockSuites {
    @MainActor
    @Suite("Link failure banner", .timeLimit(.minutes(1)))
    struct LinkFailureBannerTests {
        private static let link = "https://www.youtube.com/watch?v=9XUo28kxQt4&t=41s"

        private func makeModel() -> AppModel {
            AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("link-failure"))
        }

        @Test("a link from the sheet fails with the plain message and can be retried")
        func sheetPath() async {
            MockMediaFetcherRegistry.shared.installFailure(staleRefusal)
            defer { MockMediaFetcherRegistry.shared.clear() }
            let model = makeModel()

            model.transcribeYouTube(urlString: Self.link)

            await waitUntil { model.phase == .failed(message: staleRefusalMessage) }
            #expect(model.failedLink == .transcribe(Self.link))
            #expect(model.failedLinkDownload == staleRefusal)
            #expect(model.canRetryFailedTranscription)
        }

        @Test("a link parked behind a take ends with the same message once it runs")
        func parkedPath() async {
            MockMediaFetcherRegistry.shared.installFailure(staleRefusal)
            defer { MockMediaFetcherRegistry.shared.clear() }
            let model = makeModel()
            model.phase = .recording(source: .microphone)
            #expect(model.transcribeYouTube(urlString: Self.link) == .parked)

            model.phase = .idle
            model.drainDeferredArrivals()

            await waitUntil { model.phase == .failed(message: staleRefusalMessage) }
            #expect(model.failedLink == .transcribe(Self.link))
            #expect(model.canRetryFailedTranscription)
        }

        @Test("Retry runs the failed link again")
        func retryRunsTheLinkAgain() async {
            MockMediaFetcherRegistry.shared.installFailure(staleRefusal)
            defer { MockMediaFetcherRegistry.shared.clear() }
            let model = makeModel()
            model.transcribeYouTube(urlString: Self.link)
            await waitUntil { model.phase == .failed(message: staleRefusalMessage) }

            MockMediaFetcherRegistry.shared.installFailure(LinkDownloadFailure(reason: .unreachable, site: "YouTube"))
            model.retryFailedTranscription()

            await waitUntil {
                model.phase == .failed(message: "Couldn't reach YouTube. Check your internet connection and try again.")
            }
            #expect(model.failedLink == .transcribe(Self.link))
        }

        @Test("Update yt-dlp on the banner hands over to Retry once it succeeds")
        func updateThenRetry() async throws {
            MockMediaFetcherRegistry.shared.installFailure(staleRefusal)
            defer { MockMediaFetcherRegistry.shared.clear() }
            let brew = try fakeTool("exit 0")
            let ytDlp = try fakeTool("echo 2099.01.01")
            defer {
                try? FileManager.default.removeItem(at: brew)
                try? FileManager.default.removeItem(at: ytDlp)
            }
            let model = makeModel()
            model.transcribeYouTube(urlString: Self.link)
            await waitUntil { model.phase == .failed(message: staleRefusalMessage) }
            model.ytDlpPath = ytDlp.path
            model.ytDlpLocator = { ytDlp.path }
            model.ytDlpUpdateRoute = .homebrew(brewPath: brew.path)
            #expect(model.ytDlpUpdateOffer == .update)

            model.updateYtDlpViaBrew()

            #expect(model.ytDlpUpdateOffer == .updating)
            await waitUntil { !model.ytDlpUpdating }
            #expect(model.ytDlpUpdateOffer == .updated("2099.01.01"))
            #expect(model.canRetryFailedTranscription)
            #expect(model.phase == .failed(message: staleRefusalMessage))
        }

        @Test("Dismiss on a banner that is updating yt-dlp stops the update")
        func dismissStopsTheUpdate() async throws {
            MockMediaFetcherRegistry.shared.installFailure(staleRefusal)
            defer { MockMediaFetcherRegistry.shared.clear() }
            let brew = try fakeTool("exec sleep 30")
            let ytDlp = try fakeTool("echo 2026.03.17")
            defer {
                try? FileManager.default.removeItem(at: brew)
                try? FileManager.default.removeItem(at: ytDlp)
            }
            let model = makeModel()
            model.transcribeYouTube(urlString: Self.link)
            await waitUntil { model.phase == .failed(message: staleRefusalMessage) }
            model.ytDlpPath = ytDlp.path
            model.ytDlpLocator = { ytDlp.path }
            model.ytDlpUpdateRoute = .homebrew(brewPath: brew.path)
            model.updateYtDlpViaBrew()
            #expect(model.ytDlpUpdateOffer == .updating)

            model.dismissError()

            #expect(model.phase == .idle)
            await waitUntil { !model.ytDlpUpdating }
            #expect(model.ytDlpUpdateError == nil)
        }

        @Test("a fresh yt-dlp's failure offers only Retry")
        func freshFailureOffersOnlyRetry() async {
            let fresh = LinkDownloadFailure(reason: .refused(httpStatus: 403), site: "YouTube", ytDlpVersion: YtDlpVersion("2099.01.01"))
            MockMediaFetcherRegistry.shared.installFailure(fresh)
            defer { MockMediaFetcherRegistry.shared.clear() }
            let model = makeModel()

            model.transcribeYouTube(urlString: Self.link)

            await waitUntil { model.phase == .failed(message: "YouTube refused the download (HTTP 403). Try again later.") }
            #expect(model.ytDlpUpdateOffer == .none)
            #expect(model.canRetryFailedTranscription)
        }
    }
}
