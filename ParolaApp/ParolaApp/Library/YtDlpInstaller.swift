import Foundation

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

    static func updateRoute(ytDlpPath: String, brewPath: String?) -> UpdateRoute {
        let resolved = URL(fileURLWithPath: ytDlpPath).resolvingSymlinksInPath().path
        return updateRoute(ytDlpPath: ytDlpPath, resolvedPath: resolved, brewPath: brewPath)
    }

    /// Homebrew owns yt-dlp only when the binary resolves into that brew's Cellar; any other install gets yt-dlp's own updater.
    static func updateRoute(ytDlpPath: String, resolvedPath: String, brewPath: String?) -> UpdateRoute {
        if let brewPath {
            let prefix = URL(fileURLWithPath: brewPath).deletingLastPathComponent().deletingLastPathComponent().path
            if resolvedPath.hasPrefix(prefix + "/Cellar/yt-dlp/") { return .homebrew(brewPath: brewPath) }
        }
        return .command("\(ytDlpPath) -U")
    }

    static func install(formula: String, brewPath: String) async -> Outcome {
        await runBrew(["install", formula], brewPath: brewPath, autoUpdate: false, deadline: nil)
    }

    static func upgrade(formula: String, brewPath: String, deadline: Duration = upgradeDeadline) async -> Outcome {
        await runBrew(["upgrade", formula], brewPath: brewPath, autoUpdate: true, deadline: deadline)
    }

    static func brewEnvironment(autoUpdate: Bool) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // An upgrade needs brew's auto-update: without it brew only knows the versions it fetched last time.
        env["HOMEBREW_NO_AUTO_UPDATE"] = autoUpdate ? nil : "1"
        env["HOMEBREW_NO_ANALYTICS"] = "1"
        return env
    }

    private static func runBrew(
        _ arguments: [String], brewPath: String, autoUpdate: Bool, deadline: Duration?
    ) async -> Outcome {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: brewPath)
        proc.arguments = arguments
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
        let ending = await waitForExit(proc, deadline: deadline)
        pipe.fileHandleForReading.readabilityHandler = nil
        chunkContinuation.finish()
        let output = await bufferTask.value
        switch ending {
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .cancelled
        case .exited:
            if proc.terminationStatus == 0 { return .success }
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(detail.isEmpty ? "brew exited with status \(proc.terminationStatus)." : detail)
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
