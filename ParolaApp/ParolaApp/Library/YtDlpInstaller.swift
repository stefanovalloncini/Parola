import Foundation
import ParolaCore

/// Locates `yt-dlp`/`brew` on disk and drives `brew install` and `brew upgrade`, off the AppModel.
enum YtDlpInstaller {
    enum Outcome: Equatable, Sendable {
        case success
        case failure(String)
        case timedOut
        case cancelled
    }

    static let upgradeDeadline: Duration = .seconds(600)

    enum UpdateRoute: Equatable, Sendable {
        case homebrew(brewPath: String)
        case command(String)
        case manual
    }

    static func locate() -> String? {
        for path in ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/usr/bin/yt-dlp"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        let env = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in env.split(separator: ":") {
            let candidate = "\(dir)/yt-dlp"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func locateBrew() -> String? {
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Picks how this yt-dlp updates from what's on disk: Homebrew's Cellar, MacPorts, pipx, a pip script, or a standalone build.
    static func updateRoute(ytDlpPath: String) -> UpdateRoute {
        let resolved = URL(fileURLWithPath: ytDlpPath).resolvingSymlinksInPath().path
        if let cellar = resolved.range(of: "/Cellar/yt-dlp/") {
            let brew = String(resolved[..<cellar.lowerBound]) + "/bin/brew"
            if FileManager.default.isExecutableFile(atPath: brew) { return .homebrew(brewPath: brew) }
        }
        if resolved.hasPrefix("/opt/local/") { return .command("sudo port upgrade yt-dlp") }
        if resolved.contains("/pipx/venvs/") { return .command("pipx upgrade yt-dlp") }
        switch launcher(atPath: resolved) {
        case .pythonScript(let interpreter):
            return .command("\(shellQuoted(interpreter)) -m pip install -U yt-dlp")
        case .standalone:
            let directory = URL(fileURLWithPath: resolved).deletingLastPathComponent().path
            let writable = FileManager.default.isWritableFile(atPath: resolved)
                && FileManager.default.isWritableFile(atPath: directory)
            return .command((writable ? "" : "sudo ") + "\(shellQuoted(ytDlpPath)) -U")
        case .unknown:
            return .manual
        }
    }

    enum Launcher: Equatable {
        case pythonScript(interpreter: String)
        case standalone
        case unknown
    }

    static func launcher(atPath path: String) -> Launcher {
        guard let handle = FileHandle(forReadingAtPath: path) else { return .unknown }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4096)) ?? Data()
        let machOMagics: [[UInt8]] = [[0xCF, 0xFA, 0xED, 0xFE], [0xCE, 0xFA, 0xED, 0xFE], [0xCA, 0xFE, 0xBA, 0xBE]]
        if machOMagics.contains(where: { head.starts(with: $0) }) { return .standalone }
        guard head.starts(with: Array("#!".utf8)) else { return .unknown }
        // yt-dlp's zip build is a python shebang followed by the archive it runs, and it updates itself.
        if head.range(of: Data([0x50, 0x4B, 0x03, 0x04])) != nil { return .standalone }
        let lines = String(decoding: head, as: UTF8.self).split(separator: "\n", maxSplits: 2).map(String.init)
        let interpreter = lines.first.flatMap(shebangInterpreter)
            .flatMap { $0.contains("python") ? $0 : nil }
            ?? lines.dropFirst().first.flatMap(execLauncherInterpreter)
        guard let interpreter, interpreter.contains("python") else { return .unknown }
        return .pythonScript(interpreter: interpreter)
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

    static func shellQuoted(_ path: String) -> String {
        guard path.contains(where: { !($0.isLetter || $0.isNumber || "/._-+@".contains($0)) }) else { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    enum BrewCommand: String, LogSafe {
        case install
        case upgrade

        var logToken: String { rawValue }
    }

    enum BrewFailureKind: String, LogSafe {
        case download
        case locked
        case notInstalled
        case permission
        case other

        var logToken: String { rawValue }
    }

    static func install(formula: String, brewPath: String) async -> Outcome {
        await runBrew(.install, formula: formula, brewPath: brewPath, autoUpdate: false, deadline: nil)
    }

    static func upgrade(formula: String, brewPath: String, deadline: Duration = upgradeDeadline) async -> Outcome {
        await runBrew(.upgrade, formula: formula, brewPath: brewPath, autoUpdate: true, deadline: deadline)
    }

    /// brew's own `Error:` lines, at most the last two; auto-update reports and hints never reach the UI.
    static func errorSummary(of output: String) -> String? {
        let errors = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("Error:") }
            .map { $0.dropFirst("Error:".count).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return errors.isEmpty ? nil : errors.suffix(2).joined(separator: "\n")
    }

    static func failureKind(of summary: String?) -> BrewFailureKind {
        let text = summary?.lowercased() ?? ""
        func mentions(_ needles: [String]) -> Bool { needles.contains { text.contains($0) } }
        if mentions(["failed to download", "download failed", "curl:", "could not resolve", "timed out"]) { return .download }
        if mentions(["already in progress", "is locked", "another active homebrew"]) { return .locked }
        if mentions(["not installed", "no such keg", "no available formula"]) { return .notInstalled }
        if mentions(["permission denied", "not writable", "operation not permitted"]) { return .permission }
        return .other
    }

    static func brewEnvironment(autoUpdate: Bool) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // An upgrade needs brew's auto-update: without it brew only knows the versions it fetched last time.
        env["HOMEBREW_NO_AUTO_UPDATE"] = autoUpdate ? nil : "1"
        env["HOMEBREW_NO_ANALYTICS"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_UPDATE_REPORT_NEW"] = "1"
        return env
    }

    private static func runBrew(
        _ command: BrewCommand, formula: String, brewPath: String, autoUpdate: Bool, deadline: Duration?
    ) async -> Outcome {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: brewPath)
        proc.arguments = [command.rawValue, formula]
        proc.environment = brewEnvironment(autoUpdate: autoUpdate)
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        let (chunkStream, chunkContinuation) = AsyncStream.makeStream(of: Data.self)
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData
            if chunk.isEmpty {
                fh.readabilityHandler = nil
                chunkContinuation.finish()
            } else {
                chunkContinuation.yield(chunk)
            }
        }

        let bufferTask = Task<String, Never> {
            var data = Data()
            for await chunk in chunkStream {
                data.append(chunk)
            }
            return String(decoding: data, as: UTF8.self)
        }

        do {
            try proc.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            chunkContinuation.finish()
            return .failure("Could not launch brew: \(error.localizedDescription)")
        }
        let started = ContinuousClock.now
        let ending = await waitForExit(proc, deadline: deadline)
        pipe.fileHandleForReading.readabilityHandler = nil
        chunkContinuation.finish()
        let output = await bufferTask.value
        let elapsed = LogValue.duration(started.duration(to: .now))
        switch ending {
        case .timedOut:
            ParolaLog.error(.youtube, "brew \(command) hit its deadline", [.elapsed: elapsed])
            return .timedOut
        case .cancelled:
            ParolaLog.notice(.youtube, "brew \(command) cancelled", [.elapsed: elapsed])
            return .cancelled
        case .exited:
            let status = Int(proc.terminationStatus)
            if status == 0 {
                ParolaLog.info(.youtube, "brew \(command) finished", [.elapsed: elapsed])
                return .success
            }
            let summary = errorSummary(of: output)
            let lines = output.split(whereSeparator: \.isNewline).count
            ParolaLog.error(
                .youtube, "brew \(command) exited with status \(status)",
                [.error: .safe(failureKind(of: summary)), .count: .int(lines), .elapsed: elapsed]
            )
            return .failure(summary ?? "brew exited with status \(status).")
        }
    }

    private enum Ending: Sendable {
        case exited
        case timedOut
        case cancelled
    }

    private static func waitForExit(_ proc: Process, deadline: Duration?) async -> Ending {
        let exit = Task.detached(priority: .utility) { proc.waitUntilExit() }
        return await withTaskGroup(of: Ending.self) { group in
            group.addTask {
                await withTaskCancellationHandler {
                    await exit.value
                } onCancel: {
                    stop(proc)
                }
                return Task.isCancelled ? .cancelled : .exited
            }
            if let deadline {
                group.addTask {
                    guard (try? await Task.sleep(for: deadline)) != nil else { return .cancelled }
                    stop(proc)
                    return .timedOut
                }
            }
            let first = await group.next() ?? .exited
            group.cancelAll()
            return first
        }
    }

    /// SIGTERM lets brew release its lock; SIGKILL follows if it's still running after the grace period.
    private static func stop(_ proc: Process) {
        guard proc.isRunning else { return }
        proc.terminate()
        let pid = proc.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(10)) {
            if proc.isRunning { kill(pid, SIGKILL) }
        }
    }
}
