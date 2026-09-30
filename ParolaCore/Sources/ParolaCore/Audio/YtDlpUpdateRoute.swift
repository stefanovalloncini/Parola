#if os(macOS)
import Foundation

public enum YtDlpUpdateRoute: Equatable, Sendable {
    case homebrew(brewPath: String)
    case command(String)
    case manual

    /// Picks how this yt-dlp updates from what's on disk: Homebrew's Cellar, MacPorts, pipx, a pip script, or a standalone build.
    public init(ytDlpPath: String) {
        let resolved = URL(fileURLWithPath: ytDlpPath).resolvingSymlinksInPath().path
        if let cellar = resolved.range(of: "/Cellar/yt-dlp/") {
            let brew = String(resolved[..<cellar.lowerBound]) + "/bin/brew"
            if FileManager.default.isExecutableFile(atPath: brew) {
                self = .homebrew(brewPath: brew)
                return
            }
        }
        if resolved.hasPrefix("/opt/local/") {
            self = .command("sudo port upgrade yt-dlp")
            return
        }
        if resolved.contains("/pipx/venvs/") {
            self = .command("pipx upgrade yt-dlp")
            return
        }
        switch Launcher(atPath: resolved) {
        case .pythonScript(let interpreter):
            self = .command("\(Self.shellQuoted(interpreter)) -m pip install -U yt-dlp")
        case .standalone:
            let directory = URL(fileURLWithPath: resolved).deletingLastPathComponent().path
            let writable = FileManager.default.isWritableFile(atPath: resolved)
                && FileManager.default.isWritableFile(atPath: directory)
            self = .command((writable ? "" : "sudo ") + "\(Self.shellQuoted(ytDlpPath)) -U")
        case .unknown:
            self = .manual
        }
    }

    public var shellCommand: String? {
        switch self {
        case .homebrew(let brewPath): "\(Self.shellQuoted(brewPath)) upgrade yt-dlp"
        case .command(let command): command
        case .manual: nil
        }
    }

    static func shellQuoted(_ path: String) -> String {
        guard path.contains(where: { !($0.isLetter || $0.isNumber || "/._-+@".contains($0)) }) else { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private enum Launcher: Equatable {
        case pythonScript(interpreter: String)
        case standalone
        case unknown

        init(atPath path: String) {
            guard let handle = FileHandle(forReadingAtPath: path) else {
                self = .unknown
                return
            }
            defer { try? handle.close() }
            let head = (try? handle.read(upToCount: 4096)) ?? Data()
            let machOMagics: [[UInt8]] = [[0xCF, 0xFA, 0xED, 0xFE], [0xCE, 0xFA, 0xED, 0xFE], [0xCA, 0xFE, 0xBA, 0xBE]]
            if machOMagics.contains(where: { head.starts(with: $0) }) {
                self = .standalone
                return
            }
            guard head.starts(with: Array("#!".utf8)) else {
                self = .unknown
                return
            }
            // yt-dlp's zip build is a python shebang followed by the archive it runs, and it updates itself.
            if head.range(of: Data([0x50, 0x4B, 0x03, 0x04])) != nil {
                self = .standalone
                return
            }
            let lines = String(decoding: head, as: UTF8.self).split(separator: "\n", maxSplits: 2).map(String.init)
            let interpreter = lines.first.flatMap(Self.shebangInterpreter)
                .flatMap { $0.contains("python") ? $0 : nil }
                ?? lines.dropFirst().first.flatMap(Self.execLauncherInterpreter)
            guard let interpreter, interpreter.contains("python") else {
                self = .unknown
                return
            }
            self = .pythonScript(interpreter: interpreter)
        }

        private static func shebangInterpreter(_ line: String) -> String? {
            let words = line.dropFirst(2).split(separator: " ").map(String.init)
            guard let first = words.first else { return nil }
            return first.hasSuffix("/env") ? words.dropFirst().first : first
        }

        /// pip writes a `#!/bin/sh` launcher that re-execs python on its second line when the interpreter path is long.
        private static func execLauncherInterpreter(_ line: String) -> String? {
            let marker = "'''exec' "
            guard line.hasPrefix(marker) else { return nil }
            let rest = line.dropFirst(marker.count)
            if rest.first == "\"" {
                return rest.dropFirst().split(separator: "\"", maxSplits: 1).first.map(String.init)
            }
            return rest.split(separator: " ").first.map(String.init)
        }
    }
}
#endif
