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

    /// A throwaway directory standing in for `/`, so each install layout can be built for real.
    private final class FakeRoot {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parola-fake-root-\(UUID().uuidString)")

        deinit {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.appendingPathComponent("bin").path)
            try? FileManager.default.removeItem(at: url)
        }

        func path(_ relative: String) -> String { url.appendingPathComponent(relative).path }

        @discardableResult
        func file(_ relative: String, _ contents: Data, executable: Bool = true) throws -> String {
            let target = url.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: target)
            if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path) }
            return target.path
        }

        @discardableResult
        func text(_ relative: String, _ contents: String) throws -> String {
            try file(relative, Data(contents.utf8))
        }

        @discardableResult
        func link(_ relative: String, to destination: String) throws -> String {
            let target = url.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: destination)
            return target.path
        }
    }

    private static let pipScript = """
        #!/opt/homebrew/opt/python@3.13/bin/python3.13
        # -*- coding: utf-8 -*-
        import re
        import sys
        from yt_dlp import main
        if __name__ == "__main__":
            sys.argv[0] = re.sub(r"(-script\\.pyw|\\.exe)?$", "", sys.argv[0])
            sys.exit(main())
        """

    @Test("a yt-dlp linked from a Homebrew Cellar updates with that prefix's brew", arguments: ["opt/homebrew", "usr/local"])
    func homebrewOwned(prefix: String) throws {
        let root = FakeRoot()
        let brew = try root.text("\(prefix)/bin/brew", "#!/bin/sh\n")
        try root.text("\(prefix)/Cellar/yt-dlp/2026.3.17_2/bin/yt-dlp", "#!\(root.path(prefix))/Cellar/yt-dlp/2026.3.17_2/libexec/bin/python\nfrom yt_dlp import main\n")
        let ytDlp = try root.link("\(prefix)/bin/yt-dlp", to: "../Cellar/yt-dlp/2026.3.17_2/bin/yt-dlp")

        let resolvedBrew = URL(fileURLWithPath: brew).resolvingSymlinksInPath().path
        #expect(YtDlpInstaller.updateRoute(ytDlpPath: ytDlp) == .homebrew(brewPath: resolvedBrew))
    }

    @Test("a pip install is updated through the python that owns it")
    func pipInstall() throws {
        let root = FakeRoot()
        let ytDlp = try root.text("opt/homebrew/bin/yt-dlp", Self.pipScript)

        #expect(YtDlpInstaller.updateRoute(ytDlpPath: ytDlp) == .command("/opt/homebrew/opt/python@3.13/bin/python3.13 -m pip install -U yt-dlp"))
    }

    @Test("a pip install under env or pip's long-path launcher still finds its python", arguments: [
        ("#!/usr/bin/env python3\nfrom yt_dlp import main\n", "python3 -m pip install -U yt-dlp"),
        ("#!/bin/sh\n'''exec' \"/Users/me/Python Tools/bin/python3\" \"$0\" \"$@\"\n' '''\nfrom yt_dlp import main\n", "'/Users/me/Python Tools/bin/python3' -m pip install -U yt-dlp"),
    ])
    func pipLaunchers(script: String, command: String) throws {
        let root = FakeRoot()
        let ytDlp = try root.text("usr/local/bin/yt-dlp", script)

        #expect(YtDlpInstaller.updateRoute(ytDlpPath: ytDlp) == .command(command))
    }

    @Test("a pipx install is upgraded with pipx")
    func pipxInstall() throws {
        let root = FakeRoot()
        try root.text(".local/pipx/venvs/yt-dlp/bin/yt-dlp", "#!\(root.path(".local/pipx/venvs/yt-dlp/bin/python"))\nfrom yt_dlp import main\n")
        let ytDlp = try root.link(".local/bin/yt-dlp", to: root.path(".local/pipx/venvs/yt-dlp/bin/yt-dlp"))

        #expect(YtDlpInstaller.updateRoute(ytDlpPath: ytDlp) == .command("pipx upgrade yt-dlp"))
    }

    @Test("a standalone build updates itself", arguments: [
        Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01]),
        Data([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x02]),
        Data("#!/usr/bin/env python3\n".utf8) + Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00]),
    ])
    func standaloneBuild(contents: Data) throws {
        let root = FakeRoot()
        let ytDlp = try root.file("bin/yt-dlp", contents)

        #expect(YtDlpInstaller.updateRoute(ytDlpPath: ytDlp) == .command("\(ytDlp) -U"))
    }

    @Test("a standalone build in a folder the user can't write to needs sudo")
    func standaloneNeedsSudo() throws {
        let root = FakeRoot()
        let ytDlp = try root.file("bin/yt-dlp", Data([0xCF, 0xFA, 0xED, 0xFE]))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path("bin"))

        #expect(YtDlpInstaller.updateRoute(ytDlpPath: ytDlp) == .command("sudo \(ytDlp) -U"))
    }

    @Test("MacPorts' yt-dlp is upgraded with port")
    func macPorts() {
        #expect(YtDlpInstaller.updateRoute(ytDlpPath: "/opt/local/bin/yt-dlp") == .command("sudo port upgrade yt-dlp"))
    }

    @Test("anything else gets no command to copy", arguments: ["#!/bin/bash\nexec /somewhere/yt-dlp \"$@\"\n", ""])
    func unknownInstall(script: String) throws {
        let root = FakeRoot()
        let ytDlp = try root.text("bin/yt-dlp", script)

        #expect(YtDlpInstaller.updateRoute(ytDlpPath: ytDlp) == .manual)
        #expect(YtDlpInstaller.updateRoute(ytDlpPath: root.path("bin/missing")) == .manual)
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
