import Foundation
import Testing
@testable import ParolaCore

@Suite("Link download failure")
struct LinkDownloadFailureTests {
    /// What Homebrew's yt-dlp 2026.03.17 printed for https://www.youtube.com/watch?v=9XUo28kxQt4 on 2026-09-23.
    static let refused403 = """
        WARNING: Your yt-dlp version (2026.03.17) is older than 90 days!
                 It is strongly recommended to always use the latest version.
                 You installed yt-dlp with pip or using the wheel from PyPi; Use that to update.
                 To suppress this warning, add --no-update to your command/config.
        ERROR: unable to download video data: HTTP Error 403: Forbidden
        """

    /// The same run as the error banner quoted it, every line run together.
    static let refused403OneLine = "WARNING: Your yt-dlp version (2026.03.17) is older than 90 days! It is strongly recommended to always use the latest version. You installed yt-dlp with pip or using the wheel from PyPi; Use that to update. To suppress this warning, add --no-update to your command/config. ERROR: unable to download video data: HTTP Error 403: Forbidden"

    static let september23 = utcDate(2026, 9, 23, hour: 18)

    static func utcDate(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func read(_ stderr: String, installedVersion: String? = nil, now: Date = september23) -> LinkDownloadFailure {
        LinkDownloadFailure(
            exitStatus: 1, stderr: stderr, stdout: "", installedVersion: installedVersion, site: "YouTube", now: now
        )
    }

    @Test("the 403 from an old yt-dlp reads as a refusal with the version to update", arguments: [
        refused403, refused403OneLine,
    ])
    func refused403ReadsPlainly(stderr: String) {
        let failure = read(stderr)

        #expect(failure.reason == .refused(httpStatus: 403))
        #expect(failure.ytDlpIsStale)
        #expect(failure.ytDlpVersion?.text == "2026.03.17")
        #expect(failure.message == "YouTube refused the download (HTTP 403). Your yt-dlp (2026.03.17) is out of date — update it and try again.")
    }

    @Test("warnings and yt-dlp's own update hint never reach the message")
    func warningsStayOut() {
        let message = ParolaError.linkDownloadFailed(read(Self.refused403)).description

        #expect(!message.contains("WARNING"))
        #expect(!message.contains("pip"))
        #expect(!message.contains("--no-update"))
        #expect(!message.hasPrefix("Audio capture unavailable"))
    }

    @Test("yt-dlp's error lines are classified by what the person can do about them", arguments: [
        ("ERROR: [youtube] 9XUo28kxQt4: Sign in to confirm you\u{2019}re not a bot. Use --cookies-from-browser or --cookies for the authentication.", LinkDownloadFailure.Reason.refused(httpStatus: nil)),
        ("ERROR: [youtube] 9XUo28kxQt4: Requested format is not available. Use --list-formats for a list of available formats", .refused(httpStatus: nil)),
        ("ERROR: unable to download video data: HTTP Error 429: Too Many Requests", .refused(httpStatus: 429)),
        ("ERROR: [youtube] 9XUo28kxQt4: Video unavailable. This video has been removed by the uploader", .unavailable(.removed)),
        ("ERROR: [youtube] 9XUo28kxQt4: Private video. Sign in if you've been granted access to this video. Use --cookies-from-browser or --cookies for the authentication.", .unavailable(.privateVideo)),
        ("ERROR: [youtube] 9XUo28kxQt4: Join this channel to get access to members-only content like this video, and other exclusive perks.", .unavailable(.membersOnly)),
        ("ERROR: [youtube] 9XUo28kxQt4: Sign in to confirm your age. This video may be inappropriate for some users. Use --cookies-from-browser or --cookies for the authentication.", .unavailable(.ageRestricted)),
        ("ERROR: [youtube] 9XUo28kxQt4: The uploader has not made this video available in your country", .unavailable(.regionLocked)),
        ("ERROR: [youtube] 9XUo28kxQt4: Video unavailable. This video contains content from SME, who has blocked it in your country on copyright grounds", .unavailable(.regionLocked)),
        ("ERROR: [youtube] 9XUo28kxQt4: Video unavailable. This video contains content from SME, who has blocked it on copyright grounds", .unavailable(.blocked)),
        ("ERROR: [youtube] 9XUo28kxQt4: Video unavailable. This video is no longer available due to a copyright claim by SME", .unavailable(.blocked)),
        ("ERROR: [vimeo] 76979871: Unable to download JSON metadata: HTTP Error 404: Not Found", .unavailable(.removed)),
        ("ERROR: [youtube] 9XUo28kxQt4: Unable to download API page: <urlopen error [Errno 8] nodename nor servname provided, or not known> (caused by TransportError('<urlopen error [Errno 8] nodename nor servname provided, or not known>'))", .unreachable),
        ("ERROR: [youtube] 9XUo28kxQt4: Unable to download webpage: HTTPSConnectionPool(host='www.youtube.com', port=443): Max retries exceeded with url: /watch?v=9XUo28kxQt4 (Caused by NameResolutionError(\"Failed to resolve 'www.youtube.com'\"))", .unreachable),
        ("ERROR: [youtube] 9XUo28kxQt4: Unable to download webpage: The read operation timed out", .unreachable),
    ])
    func classifies(stderr: String, expected: LinkDownloadFailure.Reason) {
        #expect(read(stderr, installedVersion: "2026.09.20").reason == expected)
    }

    @Test("anything else keeps yt-dlp's error line, without the extractor prefix or the command-line hints", arguments: [
        ("ERROR: [youtube] 9XUo28kxQt4: Unable to extract uploader id; please report this issue on  https://github.com/yt-dlp/yt-dlp/issues?q= , filling out the appropriate issue template. Confirm you are on the latest version using  yt-dlp -U", "Unable to extract uploader id."),
        ("ERROR: Postprocessing: ffprobe and ffmpeg not found. Please install or provide the path using --ffmpeg-location", "Postprocessing: ffprobe and ffmpeg not found. Please install or provide the path using --ffmpeg-location."),
        ("ERROR: [generic] Unsupported URL: https://example.com/page", "Unsupported URL: https://example.com/page."),
    ])
    func keepsTheCleanedErrorLine(stderr: String, detail: String) {
        let failure = read(stderr, installedVersion: "2026.09.20")

        #expect(failure.reason == .toolError(detail))
        #expect(failure.message == "yt-dlp failed: \(detail)")
    }

    @Test("a crash without an ERROR line falls back to its last line, and silence to the exit status")
    func fallsBackWithoutAnErrorLine() {
        let traceback = """
            Traceback (most recent call last):
              File "/opt/homebrew/bin/yt-dlp", line 5, in <module>
                from yt_dlp import main
            ModuleNotFoundError: No module named 'yt_dlp'
            """
        #expect(read(traceback).reason == .toolError("ModuleNotFoundError: No module named 'yt_dlp'."))
        let silent = LinkDownloadFailure(exitStatus: 2, stderr: "", stdout: "", site: nil, now: Self.september23)
        #expect(silent.reason == .toolExited(status: 2))
        #expect(silent.message == "yt-dlp stopped with exit status 2.")
    }

    @Test("colour codes are stripped before the output is read")
    func stripsColourCodes() {
        let failure = read("\u{1B}[0;31mERROR:\u{1B}[0m unable to download video data: HTTP Error 403: Forbidden")
        #expect(failure.reason == .refused(httpStatus: 403))
    }

    @Test("with warnings silenced, the version alone marks yt-dlp stale")
    func staleFromVersionAlone() {
        let stderr = "ERROR: [youtube] 9XUo28kxQt4: Requested format is not available. Use --list-formats for a list of available formats"
        let failure = read(stderr, installedVersion: "2026.03.17\n")

        #expect(failure.ytDlpIsStale)
        #expect(failure.ytDlpVersion?.text == "2026.03.17")
        #expect(failure.message == "YouTube refused the download. Your yt-dlp (2026.03.17) is out of date — update it and try again.")
    }

    @Test("a fresh yt-dlp gets advice for the failure instead of an update")
    func freshVersionGetsItsHint() {
        let failure = read("ERROR: unable to download video data: HTTP Error 403: Forbidden", installedVersion: "2026.08.19")

        #expect(!failure.ytDlpIsStale)
        #expect(failure.message == "YouTube refused the download (HTTP 403). Try again later.")
    }

    @Test("the stale flag follows the injected clock, not the machine's")
    func staleFollowsTheClock() {
        let stderr = "ERROR: unable to download video data: HTTP Error 403: Forbidden"
        #expect(!read(stderr, installedVersion: "2026.03.17", now: Self.utcDate(2026, 6, 15, hour: 23)).ytDlpIsStale)
        #expect(read(stderr, installedVersion: "2026.03.17", now: Self.utcDate(2026, 6, 16)).ytDlpIsStale)
    }

    @Test("only failures a second try could change are worth retrying", arguments: [
        (LinkDownloadFailure.Reason.refused(httpStatus: 403), true),
        (.unreachable, true),
        (.timedOut(seconds: 120), true),
        (.stalled(seconds: 60), true),
        (.toolError("Unable to extract uploader id."), true),
        (.toolExited(status: 9), true),
        (.toolMissing, true),
        (.noAudio, true),
        (.unavailable(.removed), false),
        (.unavailable(.privateVideo), false),
        (.unavailable(.membersOnly), false),
        (.unavailable(.ageRestricted), false),
        (.unavailable(.regionLocked), false),
        (.unavailable(.blocked), false),
        (.noCaptions, false),
        (.unsupportedLink, false),
    ])
    func worthRetrying(reason: LinkDownloadFailure.Reason, expected: Bool) {
        #expect(LinkDownloadFailure(reason: reason, site: "YouTube").isWorthRetrying == expected)
    }

    @Test("a download that stopped moving says so, not that it ran out of time")
    func stalledReadsAsAStall() {
        let failure = LinkDownloadFailure(reason: .stalled(seconds: 60), site: "YouTube")

        #expect(failure.message == "The download stopped making progress for 60 seconds. Check your internet connection and try again.")
        #expect(failure.logToken == "stalled")
    }

    @Test("a video an update can't unlock doesn't ask for one")
    func staleButNotWorthRetrying() {
        let failure = read(
            "ERROR: [youtube] 9XUo28kxQt4: Private video. Sign in if you've been granted access to this video",
            installedVersion: "2026.03.17"
        )

        #expect(failure.ytDlpIsStale)
        #expect(failure.message == "This video can't be downloaded because it's private. Your yt-dlp (2026.03.17) is also out of date.")
        #expect(LinkDownloadFailure(reason: .noCaptions, ytDlpIsStale: true).message
            == "This video has no captions. Transcribe it instead. Your yt-dlp is also out of date.")
    }

    @Test("a timeout folds in the site and the installed version")
    func timeoutNotesVersion() {
        let failure = LinkDownloadFailure(reason: .timedOut(seconds: 120), site: "YouTube")
            .noting(installedVersion: YtDlpVersion("2026.03.17"), now: Self.september23)

        #expect(failure.ytDlpIsStale)
        #expect(failure.message == "The download didn't finish within 120 seconds. Your yt-dlp (2026.03.17) is out of date — update it and try again.")
    }

    @Test("a link failure never renders as a capture failure, and logs only its kind")
    func errorRendering() {
        let error = ParolaError.linkDownloadFailed(read(Self.refused403))

        #expect(error.description == read(Self.refused403).message)
        #expect(error.logKind == "ParolaError.linkDownloadFailed(refused.403,yt-dlp.2026.03.17,stale)")
        #expect(LogErrorKind.describe(ParolaError.linkDownloadFailed(
            read("ERROR: [youtube] 9XUo28kxQt4: Unable to extract uploader id", installedVersion: "2026.09.20")
        )) == "ParolaError.linkDownloadFailed(toolError,yt-dlp.2026.09.20)")
    }

    @Test("the site is YouTube for YouTube links and the bare host elsewhere", arguments: [
        ("https://www.youtube.com/watch?v=9XUo28kxQt4&t=41s", "YouTube"),
        ("https://youtu.be/9XUo28kxQt4", "YouTube"),
        ("https://www.vimeo.com/76979871", "vimeo.com"),
        ("https://m.facebook.com/watch/?v=1", "facebook.com"),
        ("https://soundcloud.com/artist/track", "soundcloud.com"),
    ])
    func site(url: String, expected: String) throws {
        #expect(LinkDownloadFailure.site(for: try #require(URL(string: url))) == expected)
    }
}

@Suite("yt-dlp version")
struct YtDlpVersionTests {
    @Test("a release is stale once it's more than 90 UTC days old, as yt-dlp counts it")
    func ninetyDayRule() throws {
        let version = try #require(YtDlpVersion("2026.03.17"))

        #expect(!version.isStale(asOf: LinkDownloadFailureTests.utcDate(2026, 6, 15, hour: 23)))
        #expect(version.isStale(asOf: LinkDownloadFailureTests.utcDate(2026, 6, 16)))
        #expect(!version.isStale(asOf: LinkDownloadFailureTests.utcDate(2026, 3, 17)))
    }

    @Test("what --version prints is read from its first line", arguments: [
        ("2026.03.17\n", "2026.03.17"),
        ("  2026.08.19  ", "2026.08.19"),
        ("2026.09.20.232811\n", "2026.09.20.232811"),
    ])
    func parsesVersions(output: String, text: String) throws {
        #expect(try #require(YtDlpVersion(output)).text == text)
    }

    @Test("output that isn't a version is refused", arguments: [
        "", "Traceback (most recent call last):", "yt-dlp 2026.03.17", "/opt/homebrew/bin/yt-dlp",
    ])
    func refusesNonVersions(output: String) {
        #expect(YtDlpVersion(output) == nil)
    }

    @Test("a version without a real release day is never called stale", arguments: [
        "1.2.3", "2026.02.31", "2026.13.01",
    ])
    func undatedIsNeverStale(output: String) throws {
        #expect(try #require(YtDlpVersion(output)).isStale(asOf: LinkDownloadFailureTests.september23) == false)
    }
}

#if os(macOS)
@Suite("yt-dlp process helpers", .timeLimit(.minutes(1)))
struct YtDlpProcessTests {
    private func script(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parola-fake-yt-dlp-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test("the installed version comes from --version")
    func readsInstalledVersion() async throws {
        let fake = try script(#"[ "$1" = "--version" ] && echo 2026.03.17"#)
        defer { try? FileManager.default.removeItem(at: fake) }

        #expect(await YtDlpVersion.installed(at: fake.path)?.text == "2026.03.17")
    }

    @Test("a yt-dlp that fails or can't run has no version")
    func noVersionWhenItFails() async throws {
        let failing = try script("exit 1")
        defer { try? FileManager.default.removeItem(at: failing) }

        #expect(await YtDlpVersion.installed(at: failing.path) == nil)
        #expect(await YtDlpVersion.installed(at: "/nonexistent/yt-dlp") == nil)
    }

    @Test("a failed run is read with the version the installed yt-dlp reports")
    func failureAsksForTheVersion() async throws {
        let fake = try script("echo 2026.03.17")
        defer { try? FileManager.default.removeItem(at: fake) }

        let failure = await YouTubeProcess.failure(
            exitStatus: 1,
            stderr: "ERROR: [youtube] 9XUo28kxQt4: Requested format is not available",
            stdout: "",
            ytDlpPath: fake.path,
            site: "YouTube"
        )

        #expect(failure.reason == .refused(httpStatus: nil))
        #expect(failure.ytDlpVersion?.text == "2026.03.17")
        #expect(failure.ytDlpIsStale)
    }

    @Test("a download that overruns its timeout fails as a link download with its site")
    func timeoutIsALinkFailure() async throws {
        let fake = try script(#"[ "$1" = "--version" ] && exit 1; exec sleep 5"#)
        defer { try? FileManager.default.removeItem(at: fake) }

        do {
            _ = try await YouTubeProcess.fetch(
                ytDlpPath: fake.path, arguments: [], run: .download, watch: .wallClock(seconds: 0), site: "YouTube"
            )
            Issue.record("expected the wait to time out")
        } catch ParolaError.linkDownloadFailed(let failure) {
            #expect(failure.reason == .timedOut(seconds: 0))
            #expect(failure.site == "YouTube")
            #expect(failure.ytDlpVersion == nil)
        }
    }
}
#endif
