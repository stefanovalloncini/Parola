#if os(macOS)
import Foundation
import Testing
import ParolaCore

@Suite("yt-dlp update route")
struct YtDlpUpdateRouteTests {
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
        #expect(YtDlpUpdateRoute(ytDlpPath: ytDlp) == .homebrew(brewPath: resolvedBrew))
    }

    @Test("a pip install is updated through the python that owns it")
    func pipInstall() throws {
        let root = FakeRoot()
        let ytDlp = try root.text("opt/homebrew/bin/yt-dlp", Self.pipScript)

        #expect(YtDlpUpdateRoute(ytDlpPath: ytDlp) == .command("/opt/homebrew/opt/python@3.13/bin/python3.13 -m pip install -U yt-dlp"))
    }

    @Test("a pip install under env or pip's long-path launcher still finds its python", arguments: [
        ("#!/usr/bin/env python3\nfrom yt_dlp import main\n", "python3 -m pip install -U yt-dlp"),
        ("#!/bin/sh\n'''exec' \"/Users/me/Python Tools/bin/python3\" \"$0\" \"$@\"\n' '''\nfrom yt_dlp import main\n", "'/Users/me/Python Tools/bin/python3' -m pip install -U yt-dlp"),
    ])
    func pipLaunchers(script: String, command: String) throws {
        let root = FakeRoot()
        let ytDlp = try root.text("usr/local/bin/yt-dlp", script)

        #expect(YtDlpUpdateRoute(ytDlpPath: ytDlp) == .command(command))
    }

    @Test("a pipx install is upgraded with pipx")
    func pipxInstall() throws {
        let root = FakeRoot()
        try root.text(".local/pipx/venvs/yt-dlp/bin/yt-dlp", "#!\(root.path(".local/pipx/venvs/yt-dlp/bin/python"))\nfrom yt_dlp import main\n")
        let ytDlp = try root.link(".local/bin/yt-dlp", to: root.path(".local/pipx/venvs/yt-dlp/bin/yt-dlp"))

        #expect(YtDlpUpdateRoute(ytDlpPath: ytDlp) == .command("pipx upgrade yt-dlp"))
    }

    @Test("a standalone build updates itself", arguments: [
        Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01]),
        Data([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x02]),
        Data("#!/usr/bin/env python3\n".utf8) + Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00]),
    ])
    func standaloneBuild(contents: Data) throws {
        let root = FakeRoot()
        let ytDlp = try root.file("bin/yt-dlp", contents)

        #expect(YtDlpUpdateRoute(ytDlpPath: ytDlp) == .command("\(ytDlp) -U"))
    }

    @Test("a standalone build in a folder the user can't write to needs sudo")
    func standaloneNeedsSudo() throws {
        let root = FakeRoot()
        let ytDlp = try root.file("bin/yt-dlp", Data([0xCF, 0xFA, 0xED, 0xFE]))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path("bin"))

        #expect(YtDlpUpdateRoute(ytDlpPath: ytDlp) == .command("sudo \(ytDlp) -U"))
    }

    @Test("MacPorts' yt-dlp is upgraded with port")
    func macPorts() {
        #expect(YtDlpUpdateRoute(ytDlpPath: "/opt/local/bin/yt-dlp") == .command("sudo port upgrade yt-dlp"))
    }

    @Test("anything else gets no command to copy", arguments: ["#!/bin/bash\nexec /somewhere/yt-dlp \"$@\"\n", ""])
    func unknownInstall(script: String) throws {
        let root = FakeRoot()
        let ytDlp = try root.text("bin/yt-dlp", script)

        #expect(YtDlpUpdateRoute(ytDlpPath: ytDlp) == .manual)
        #expect(YtDlpUpdateRoute(ytDlpPath: root.path("bin/missing")) == .manual)
    }

    @Test("each route offers the shell command a person would run", arguments: [
        (YtDlpUpdateRoute.homebrew(brewPath: "/opt/homebrew/bin/brew"), "/opt/homebrew/bin/brew upgrade yt-dlp"),
        (YtDlpUpdateRoute.homebrew(brewPath: "/Users/me/Home Brew/bin/brew"), "'/Users/me/Home Brew/bin/brew' upgrade yt-dlp"),
        (YtDlpUpdateRoute.command("pipx upgrade yt-dlp"), "pipx upgrade yt-dlp"),
    ])
    func shellCommand(route: YtDlpUpdateRoute, command: String) {
        #expect(route.shellCommand == command)
    }

    @Test("a manual route has no command")
    func manualHasNoCommand() {
        #expect(YtDlpUpdateRoute.manual.shellCommand == nil)
    }
}
#endif
