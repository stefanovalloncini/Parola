import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@Suite("yt-dlp update", .timeLimit(.minutes(1)))
struct YtDlpUpdateTests {
    @MainActor
    private func makeModel() -> AppModel {
        AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("ytdlp-update"))
    }

    private func italianBundle() throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test("an upgrade that runs past its deadline is stopped")
    func upgradeDeadline() async throws {
        let brew = try script("exec sleep 30")
        defer { try? FileManager.default.removeItem(at: brew) }
        let started = ContinuousClock.now

        let outcome = await YtDlpInstaller.upgrade(formula: "yt-dlp", brewPath: brew.path, deadline: .milliseconds(200))

        #expect(outcome == .timedOut)
        #expect(started.duration(to: .now) < .seconds(10))
    }

    @Test("cancelling an upgrade stops brew")
    func upgradeCancel() async throws {
        let brew = try script("exec sleep 30")
        defer { try? FileManager.default.removeItem(at: brew) }
        let upgrade = Task { await YtDlpInstaller.upgrade(formula: "yt-dlp", brewPath: brew.path) }
        try await Task.sleep(for: .milliseconds(200))

        upgrade.cancel()

        #expect(await upgrade.value == .cancelled)
    }

    @Test("the deadline message names the minutes, in English and Italian")
    func deadlineMessage() throws {
        #expect(AppModel.ytDlpUpdateTimedOutMessage(YtDlpInstaller.upgradeDeadline)
            == "Homebrew didn't finish within 10 minutes, so Parola stopped the update.")
        #expect(AppModel.ytDlpUpdateTimedOutMessage(YtDlpInstaller.upgradeDeadline, bundle: try italianBundle())
            == "Homebrew non ha terminato entro 10 minuti, quindi Parola ha interrotto l'aggiornamento.")
    }

    @MainActor
    @Test("an update that overruns its deadline stops and says so")
    func updateDeadline() async throws {
        let brew = try script("exec sleep 30")
        let ytDlp = try script("echo 2026.03.17")
        defer {
            try? FileManager.default.removeItem(at: brew)
            try? FileManager.default.removeItem(at: ytDlp)
        }
        let model = makeModel()
        model.ytDlpPath = ytDlp.path
        model.ytDlpLocator = { ytDlp.path }
        model.ytDlpVersion = YtDlpVersion("2026.03.17")
        model.ytDlpUpdateRoute = .homebrew(brewPath: brew.path)
        model.ytDlpUpdateDeadline = .milliseconds(200)

        model.updateYtDlpViaBrew()

        await waitUntil { !model.ytDlpUpdating }
        #expect(model.ytDlpUpdateError == AppModel.ytDlpUpdateTimedOutMessage(.milliseconds(200)))
    }

    @MainActor
    @Test("Cancel ends a running update without an error")
    func cancelEndsTheUpdate() async throws {
        let brew = try script("exec sleep 30")
        let ytDlp = try script("echo 2026.03.17")
        defer {
            try? FileManager.default.removeItem(at: brew)
            try? FileManager.default.removeItem(at: ytDlp)
        }
        let model = makeModel()
        model.ytDlpPath = ytDlp.path
        model.ytDlpLocator = { ytDlp.path }
        model.ytDlpVersion = YtDlpVersion("2026.03.17")
        model.ytDlpUpdateRoute = .homebrew(brewPath: brew.path)

        model.updateYtDlpViaBrew()
        #expect(model.ytDlpUpdating)
        model.cancelYtDlpUpdate()

        await waitUntil { !model.ytDlpUpdating }
        #expect(model.ytDlpUpdateError == nil)
    }

    private func script(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parola-fake-tool-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private static let failedUpgradeOutput = """
        ==> Auto-updating Homebrew...
        Adjust how often this is run with HOMEBREW_AUTO_UPDATE_SECS or disable with
        HOMEBREW_NO_AUTO_UPDATE. Hide these hints with HOMEBREW_NO_ENV_HINTS (see `man brew`).
        ==> Updated Homebrew from 4.6.1 to 4.6.12.
        ==> New Formulae
        aaa
        zzz
        You have 12 outdated formulae installed.
        ==> Upgrading 1 outdated package:
        yt-dlp 2026.3.17_2 -> 2026.9.20
        ==> Fetching yt-dlp
        Error: yt-dlp: Failed to download resource "yt-dlp_bottle_manifest"
        Download failed: https://ghcr.io/v2/homebrew/core/yt-dlp/manifests/2026.9.20
        """

    @Test("a failed upgrade shows only brew's Error line")
    func errorSummaryKeepsOnlyErrors() {
        #expect(YtDlpInstaller.errorSummary(of: Self.failedUpgradeOutput) == "yt-dlp: Failed to download resource \"yt-dlp_bottle_manifest\"")
        #expect(YtDlpInstaller.errorSummary(of: "==> Fetching yt-dlp\nWarning: something\n") == nil)
        #expect(YtDlpInstaller.errorSummary(of: "Error: one\nError: two\nError: three\n") == "two\nthree")
    }

    @Test("a failure is logged by kind", arguments: [
        ("yt-dlp: Failed to download resource \"yt-dlp\"", YtDlpInstaller.BrewFailureKind.download),
        ("Another active Homebrew update process is already in progress.", .locked),
        ("yt-dlp not installed", .notInstalled),
        ("Permission denied @ apply2files - /opt/homebrew/bin/yt-dlp", .permission),
        ("Something unexpected", .other),
    ])
    func failureKinds(summary: String, kind: YtDlpInstaller.BrewFailureKind) {
        #expect(YtDlpInstaller.failureKind(of: summary) == kind)
    }

    @Test("brew runs without its hints and new-formula lists")
    func quieterBrew() {
        let env = YtDlpInstaller.brewEnvironment(autoUpdate: true)
        #expect(env["HOMEBREW_NO_ENV_HINTS"] == "1")
        #expect(env["HOMEBREW_NO_UPDATE_REPORT_NEW"] == "1")
    }

    @Test("an upgrade lets brew refresh its formulae, an install doesn't")
    func autoUpdate() {
        #expect(YtDlpInstaller.brewEnvironment(autoUpdate: true)["HOMEBREW_NO_AUTO_UPDATE"] == nil)
        #expect(YtDlpInstaller.brewEnvironment(autoUpdate: false)["HOMEBREW_NO_AUTO_UPDATE"] == "1")
        #expect(YtDlpInstaller.brewEnvironment(autoUpdate: true)["HOMEBREW_NO_ANALYTICS"] == "1")
    }

    @Test("Update with Homebrew runs brew upgrade yt-dlp")
    func upgradeRunsBrew() async throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("parola-fake-brew-\(UUID().uuidString)")
        let brew = try script("echo \"$@\" > '\(log.path)'")
        defer {
            try? FileManager.default.removeItem(at: brew)
            try? FileManager.default.removeItem(at: log)
        }

        let outcome = await YtDlpInstaller.upgrade(formula: "yt-dlp", brewPath: brew.path)

        guard case .success = outcome else {
            Issue.record("expected the upgrade to succeed, got \(outcome)")
            return
        }
        #expect(try String(contentsOf: log, encoding: .utf8) == "upgrade yt-dlp\n")
    }

    @Test("the Error line brew prints just before it exits is kept")
    func keepsTheLastLine() async throws {
        let brew = try script("yes '==> noise' | head -n 5000; echo 'Error: yt-dlp: Failed to download resource' >&2; exit 1")
        defer { try? FileManager.default.removeItem(at: brew) }

        let outcome = await YtDlpInstaller.upgrade(formula: "yt-dlp", brewPath: brew.path)

        #expect(outcome == .failure("yt-dlp: Failed to download resource"))
    }

    @Test("a child that keeps brew's output open doesn't hold the result")
    func childHoldingThePipe() async throws {
        let brew = try script("sleep 20 &\necho 'Error: yt-dlp not installed'\nexit 1")
        defer { try? FileManager.default.removeItem(at: brew) }
        let started = ContinuousClock.now

        let outcome = await YtDlpInstaller.upgrade(formula: "yt-dlp", brewPath: brew.path)

        #expect(outcome == .failure("yt-dlp not installed"))
        #expect(started.duration(to: .now) < .seconds(10))
    }

    @Test("brew's own failures read in English and Italian")
    func brewMessagesAreLocalized() throws {
        let italian = try italianBundle()

        #expect(YtDlpInstaller.exitStatusMessage(3) == "brew exited with status 3.")
        #expect(YtDlpInstaller.exitStatusMessage(3, bundle: italian) == "brew è terminato con codice di uscita 3.")
        #expect(YtDlpInstaller.launchFailureMessage("no such file") == "Could not launch brew: no such file")
        #expect(YtDlpInstaller.launchFailureMessage("no such file", bundle: italian) == "Impossibile avviare brew: no such file")
    }

    @Test("a brew that can't start says so")
    func brewThatCantStart() async {
        let outcome = await YtDlpInstaller.upgrade(formula: "yt-dlp", brewPath: "/nonexistent/brew")

        guard case .failure(let message) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(message.hasPrefix("Could not launch brew: "))
    }

    @Test("a failed upgrade reports what brew printed")
    func failedUpgradeReportsOutput() async throws {
        let brew = try script("echo 'Error: yt-dlp not installed' >&2; exit 1")
        defer { try? FileManager.default.removeItem(at: brew) }

        let outcome = await YtDlpInstaller.upgrade(formula: "yt-dlp", brewPath: brew.path)

        guard case .failure(let message) = outcome else {
            Issue.record("expected the upgrade to fail, got \(outcome)")
            return
        }
        #expect(message == "yt-dlp not installed")
    }

    @MainActor
    @Test("after an update the row shows the new version without the warning")
    func updateRefreshesTheVersion() async throws {
        let brew = try script("exit 0")
        let ytDlp = try script("echo 2099.01.01")
        defer {
            try? FileManager.default.removeItem(at: brew)
            try? FileManager.default.removeItem(at: ytDlp)
        }
        let model = makeModel()
        model.ytDlpPath = ytDlp.path
        model.ytDlpLocator = { ytDlp.path }
        model.ytDlpVersion = YtDlpVersion("2026.03.17")
        model.ytDlpUpdateRoute = .homebrew(brewPath: brew.path)
        #expect(model.ytDlpIsStale)

        model.updateYtDlpViaBrew()

        #expect(model.ytDlpUpdating)
        await waitUntil { !model.ytDlpUpdating }
        #expect(model.ytDlpVersion?.text == "2099.01.01")
        #expect(!model.ytDlpIsStale)
        #expect(model.ytDlpUpdateError == nil)
        #expect(model.ytDlpAvailable)
    }

    @MainActor
    @Test("an update that leaves no yt-dlp behind shows it as missing")
    func updateThatRemovesTheBinary() async throws {
        let ytDlp = try script("echo 2026.03.17")
        let brew = try script("rm -f '\(ytDlp.path)'\necho 'Error: yt-dlp: Failed to download resource' >&2\nexit 1")
        defer {
            try? FileManager.default.removeItem(at: brew)
            try? FileManager.default.removeItem(at: ytDlp)
        }
        let model = makeModel()
        model.ytDlpPath = ytDlp.path
        model.ytDlpLocator = { FileManager.default.isExecutableFile(atPath: ytDlp.path) ? ytDlp.path : nil }
        model.ytDlpAvailable = true
        model.ytDlpVersion = YtDlpVersion("2026.03.17")
        model.ytDlpUpdateRoute = .homebrew(brewPath: brew.path)

        model.updateYtDlpViaBrew()

        await waitUntil { !model.ytDlpUpdating }
        #expect(!model.ytDlpAvailable)
        #expect(model.ytDlpVersion == nil)
        #expect(model.ytDlpUpdateError == "yt-dlp: Failed to download resource")
    }

    @MainActor
    @Test("an update after which yt-dlp's version can't be read says so")
    func unreadableVersionAfterUpdate() async throws {
        let brew = try script("exit 0")
        let ytDlp = try script("echo 'Traceback (most recent call last):'")
        defer {
            try? FileManager.default.removeItem(at: brew)
            try? FileManager.default.removeItem(at: ytDlp)
        }
        let model = makeModel()
        model.ytDlpPath = ytDlp.path
        model.ytDlpLocator = { ytDlp.path }
        model.ytDlpVersion = YtDlpVersion("2026.03.17")
        model.ytDlpUpdateRoute = .homebrew(brewPath: brew.path)

        model.updateYtDlpViaBrew()

        await waitUntil { !model.ytDlpUpdating }
        #expect(model.ytDlpVersion == nil)
        #expect(model.ytDlpUpdateError == "Homebrew finished, but Parola couldn't read yt-dlp's version.")
    }

    @MainActor
    @Test("an update that leaves yt-dlp old says so")
    func updateThatChangesNothing() async throws {
        let brew = try script("exit 0")
        let ytDlp = try script("echo 2026.03.17")
        defer {
            try? FileManager.default.removeItem(at: brew)
            try? FileManager.default.removeItem(at: ytDlp)
        }
        let model = makeModel()
        model.ytDlpPath = ytDlp.path
        model.ytDlpLocator = { ytDlp.path }
        model.ytDlpVersion = YtDlpVersion("2026.03.17")
        model.ytDlpUpdateRoute = .homebrew(brewPath: brew.path)

        model.updateYtDlpViaBrew()

        await waitUntil { !model.ytDlpUpdating }
        #expect(model.ytDlpIsStale)
        #expect(model.ytDlpUpdateError == "Homebrew finished, but yt-dlp is still out of date.")
    }

    @MainActor
    @Test("a fresh yt-dlp clears the last update's error")
    func freshVersionClearsTheError() async throws {
        let ytDlp = try script("echo 2099.01.01")
        defer { try? FileManager.default.removeItem(at: ytDlp) }
        let model = makeModel()
        model.ytDlpLocator = { ytDlp.path }
        model.ytDlpUpdateError = "yt-dlp: Failed to download resource"

        model.refreshYtDlpStatus()

        await waitUntil { model.ytDlpVersion?.text == "2099.01.01" }
        #expect(model.ytDlpUpdateError == nil)
    }

    @MainActor
    @Test("a yt-dlp that is still out of date keeps the last update's error")
    func staleVersionKeepsTheError() async throws {
        let ytDlp = try script("echo 2026.03.17")
        defer { try? FileManager.default.removeItem(at: ytDlp) }
        let model = makeModel()
        model.ytDlpLocator = { ytDlp.path }
        model.ytDlpUpdateError = "yt-dlp: Failed to download resource"

        model.refreshYtDlpStatus()

        await waitUntil { model.ytDlpVersion?.text == "2026.03.17" }
        #expect(model.ytDlpUpdateError == "yt-dlp: Failed to download resource")
    }

    @MainActor
    @Test("a yt-dlp Homebrew doesn't own is never handed to brew")
    func commandRouteHasNoButtonAction() {
        let model = makeModel()
        model.ytDlpPath = "/usr/local/bin/yt-dlp"
        model.ytDlpVersion = YtDlpVersion("2026.03.17")
        model.ytDlpUpdateRoute = .command("/usr/local/bin/yt-dlp -U")

        model.updateYtDlpViaBrew()

        #expect(!model.ytDlpUpdating)
    }
}
