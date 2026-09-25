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

    @Test("a yt-dlp that resolves into brew's Cellar updates with Homebrew", arguments: [
        ("/opt/homebrew/bin/yt-dlp", "/opt/homebrew/Cellar/yt-dlp/2026.3.17_2/bin/yt-dlp", "/opt/homebrew/bin/brew"),
        ("/usr/local/bin/yt-dlp", "/usr/local/Cellar/yt-dlp/2026.3.17/bin/yt-dlp", "/usr/local/bin/brew"),
    ])
    func homebrewOwned(path: String, resolved: String, brew: String) {
        #expect(YtDlpInstaller.updateRoute(ytDlpPath: path, resolvedPath: resolved, brewPath: brew) == .homebrew(brewPath: brew))
    }

    @Test("any other yt-dlp gets its own updater's command", arguments: [
        ("/usr/local/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/opt/homebrew/bin/brew" as String?),
        ("/opt/homebrew/bin/yt-dlp", "/opt/homebrew/bin/yt-dlp", "/opt/homebrew/bin/brew"),
        ("/opt/local/bin/yt-dlp", "/opt/local/bin/yt-dlp", "/opt/homebrew/bin/brew"),
        ("/usr/local/bin/yt-dlp", "/usr/local/Cellar/yt-dlp/2026.3.17/bin/yt-dlp", nil),
    ])
    func otherInstalls(path: String, resolved: String, brew: String?) {
        #expect(YtDlpInstaller.updateRoute(ytDlpPath: path, resolvedPath: resolved, brewPath: brew) == .command("\(path) -U"))
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

    @Test("a failed upgrade reports what brew printed")
    func failedUpgradeReportsOutput() async throws {
        let brew = try script("echo 'Error: yt-dlp not installed' >&2; exit 1")
        defer { try? FileManager.default.removeItem(at: brew) }

        let outcome = await YtDlpInstaller.upgrade(formula: "yt-dlp", brewPath: brew.path)

        guard case .failure(let message) = outcome else {
            Issue.record("expected the upgrade to fail, got \(outcome)")
            return
        }
        #expect(message == "Error: yt-dlp not installed")
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
        model.ytDlpVersion = YtDlpVersion("2026.03.17")
        model.ytDlpUpdateRoute = .homebrew(brewPath: brew.path)
        #expect(model.ytDlpIsStale)

        model.updateYtDlpViaBrew()

        #expect(model.ytDlpUpdating)
        await waitUntil { !model.ytDlpUpdating }
        #expect(model.ytDlpVersion?.text == "2099.01.01")
        #expect(!model.ytDlpIsStale)
        #expect(model.ytDlpUpdateError == nil)
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
        model.ytDlpVersion = YtDlpVersion("2026.03.17")
        model.ytDlpUpdateRoute = .homebrew(brewPath: brew.path)

        model.updateYtDlpViaBrew()

        await waitUntil { !model.ytDlpUpdating }
        #expect(model.ytDlpIsStale)
        #expect(model.ytDlpUpdateError == "Homebrew finished, but yt-dlp is still out of date.")
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
