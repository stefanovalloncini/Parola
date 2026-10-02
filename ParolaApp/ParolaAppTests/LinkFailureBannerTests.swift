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
        route: YtDlpUpdateRoute? = .homebrew(brewPath: "/opt/homebrew/bin/brew"),
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

        private func makeModel(failing failure: LinkDownloadFailure = staleRefusal) -> AppModel {
            let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("link-failure"))
            model.linkFetcher = FixtureLinkFetcher(failure: failure)
            return model
        }

        @Test("a link from the sheet fails with the plain message and can be retried")
        func sheetPath() async {
            let model = makeModel()

            model.transcribeYouTube(urlString: Self.link)

            await waitUntil { model.phase == .failed(message: staleRefusalMessage) }
            #expect(model.failedLink == .transcribe(Self.link))
            #expect(model.failedLinkDownload == staleRefusal)
            #expect(model.canRetryFailedTranscription)
        }

        @Test("a link parked behind a take ends with the same message once it runs")
        func parkedPath() async {
            let model = makeModel()
            model.installTestTake(source: .microphone)
            #expect(model.transcribeYouTube(urlString: Self.link) == .parked)

            model.endTestTake()
            model.drainDeferredArrivals()

            await waitUntil { model.phase == .failed(message: staleRefusalMessage) }
            #expect(model.failedLink == .transcribe(Self.link))
            #expect(model.canRetryFailedTranscription)
        }

        @Test("Retry runs the failed link again")
        func retryRunsTheLinkAgain() async {
            let model = makeModel()
            model.transcribeYouTube(urlString: Self.link)
            await waitUntil { model.phase == .failed(message: staleRefusalMessage) }

            model.linkFetcher = FixtureLinkFetcher(failure: LinkDownloadFailure(reason: .unreachable, site: "YouTube"))
            model.retryFailedTranscription()

            await waitUntil {
                model.phase == .failed(message: "Couldn't reach YouTube. Check your internet connection and try again.")
            }
            #expect(model.failedLink == .transcribe(Self.link))
        }

        @Test("Update yt-dlp on the banner hands over to Retry once it succeeds")
        func updateThenRetry() async throws {
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
            let update = try #require(model.ytDlpUpdateTask)

            #expect(model.ytDlpUpdateOffer == .updating)
            await awaitGuarded("the yt-dlp update") { await update.value }
            #expect(!model.ytDlpUpdating)
            #expect(model.ytDlpUpdateOffer == .updated("2099.01.01"))
            #expect(model.canRetryFailedTranscription)
            #expect(model.phase == .failed(message: staleRefusalMessage))
        }

        @Test("Dismiss on a banner that is updating yt-dlp stops the update")
        func dismissStopsTheUpdate() async throws {
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

        @Test("a video that can't be downloaded offers no Retry", arguments: [
            LinkDownloadFailure(reason: .unavailable(.privateVideo), site: "YouTube"),
            LinkDownloadFailure(reason: .unavailable(.ageRestricted), site: "YouTube", ytDlpVersion: YtDlpVersion("2026.03.17"), ytDlpIsStale: true),
        ])
        func noRetryForUnavailableVideos(failure: LinkDownloadFailure) async {
            let model = makeModel(failing: failure)

            model.transcribeYouTube(urlString: Self.link)

            await waitUntil { model.phase == .failed(message: AppModel.linkFailureMessage(failure)) }
            #expect(model.failedLink == nil)
            #expect(!model.canRetryFailedTranscription)
        }

        @Test("missing captions offer no Retry")
        func noRetryForMissingCaptions() {
            let model = makeModel()

            model.applyTranscriptionError(
                ParolaError.linkDownloadFailed(LinkDownloadFailure(reason: .noCaptions, site: "YouTube")),
                link: .subtitles(Self.link)
            )

            #expect(model.phase == .failed(message: "This video has no captions. Transcribe it instead."))
            #expect(!model.canRetryFailedTranscription)
        }

        @Test("a fresh yt-dlp's failure offers only Retry")
        func freshFailureOffersOnlyRetry() async {
            let fresh = LinkDownloadFailure(reason: .refused(httpStatus: 403), site: "YouTube", ytDlpVersion: YtDlpVersion("2099.01.01"))
            let model = makeModel(failing: fresh)

            model.transcribeYouTube(urlString: Self.link)

            await waitUntil { model.phase == .failed(message: "YouTube refused the download (HTTP 403). Try again later.") }
            #expect(model.ytDlpUpdateOffer == .none)
            #expect(model.canRetryFailedTranscription)
        }
    }

    @MainActor
    @Suite("A run starting over an unseen failure")
    struct UnseenFailureBeforeARunTests {
        private static let pinnedModel = "openai_whisper-tiny"
        private static let link = "https://www.youtube.com/watch?v=9XUo28kxQt4&t=41s"

        @Test("beginFileTranscription posts the failure nobody saw as a notice")
        func fileRunPostsTheFailure() async throws {
            let audio = try makeTakeWAV("unseen-failure-file")
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                await installMockTranscriber(segments: [(0, 1, "hi")])
                let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("unseen-failure-file"))
                model.useStreaming = false
                model.selectedModel = Self.pinnedModel
                model.route = .statistics
                model.phase = .failed(message: "Couldn't start live captions")

                model.beginFileTranscription(fileURL: audio, translateOverride: nil)

                let notice = try #require(await waitForNotice(model))
                #expect(notice.message == "Couldn't start live captions")
                #expect(notice.tone == .failure)
            }
        }

        @Test("transcribeNow posts the failure nobody saw as a notice before routing to the transcript")
        func dropNowPostsTheFailure() async throws {
            let audio = try makeTakeWAV("unseen-failure-drop")
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                await installMockTranscriber(segments: [(0, 1, "hi")])
                let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("unseen-failure-drop"))
                model.useStreaming = false
                model.selectedModel = Self.pinnedModel
                model.route = .statistics
                model.phase = .failed(message: "Couldn't start live captions")

                model.transcribeNow(urls: [audio])

                let notice = try #require(await waitForNotice(model))
                #expect(notice.message == "Couldn't start live captions")
                #expect(notice.tone == .failure)
            }
        }

        @Test("the gated Add to Queue fallback posts the failure nobody saw as a notice")
        func addToQueueFallbackPostsTheFailure() async throws {
            let audio = try makeTakeWAV("unseen-failure-queue-fallback")
            defer { try? FileManager.default.removeItem(at: audio) }
            try await withMocksCleared(.transcriber) {
                await installMockTranscriber(segments: [(0, 1, "hi")])
                let model = AppModel(
                    skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("unseen-failure-queue-fallback"),
                    features: Set(ParolaFeature.allCases).subtracting([.batch])
                )
                model.useStreaming = false
                model.selectedModel = Self.pinnedModel
                model.route = .statistics
                model.phase = .failed(message: "Couldn't start live captions")

                model.addToQueue(urls: [audio])

                let notice = try #require(await waitForNotice(model))
                #expect(notice.message == "Couldn't start live captions")
                #expect(notice.tone == .failure)
            }
        }

        @Test("transcribeYouTube posts the failure nobody saw as a notice")
        func linkRunPostsTheFailure() async {
            let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("unseen-failure-link"))
            model.linkFetcher = FixtureLinkFetcher(failure: staleRefusal)
            model.route = .statistics
            model.phase = .failed(message: "Couldn't open Voice memo 3")

            model.transcribeYouTube(urlString: Self.link)

            #expect(model.exportNotice?.message == "Couldn't open Voice memo 3")
            #expect(model.exportNotice?.tone == .failure)
            #expect(model.phase == .fetchingLink(title: nil, progress: nil))
            let failed = await waitUntil { model.exportNotice?.message == "Couldn't transcribe \(Self.link). \(staleRefusalMessage)" }
            #expect(failed, "the run's own failure, away from its page, says so in a notice too")
            #expect(model.phase == .idle)
        }
    }
}
