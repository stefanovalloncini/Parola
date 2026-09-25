import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@Suite("yt-dlp update")
struct YtDlpUpdateTests {
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
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("ytdlp-update"))
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
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("ytdlp-update"))
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
        let model = AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("ytdlp-update"))
        model.ytDlpPath = "/usr/local/bin/yt-dlp"
        model.ytDlpVersion = YtDlpVersion("2026.03.17")
        model.ytDlpUpdateRoute = .command("/usr/local/bin/yt-dlp -U")

        model.updateYtDlpViaBrew()

        #expect(!model.ytDlpUpdating)
    }
}
