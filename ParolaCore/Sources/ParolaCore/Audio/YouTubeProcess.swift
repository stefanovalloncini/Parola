#if os(macOS)
import Foundation
import os

/// What a yt-dlp run is for, so a timeout in the log says which one stalled.
enum YtDlpRun: String, LogSafe {
    case download
    case captions
    case versionCheck

    var logToken: String { rawValue }
}

/// Where yt-dlp is: the one lookup both the downloads and Settings use.
public enum YtDlpLocator {
    public static func locate() -> String? {
        for candidate in ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/usr/bin/yt-dlp"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        let env = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in env.split(separator: ":") {
            let candidate = "\(dir)/yt-dlp"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public static func locateBrew() -> String? {
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}

enum YouTubeProcess {
    /// Launches `process` with its exit signal wired up first, so a quick exit can't slip past the wait.
    static func start(_ process: Process) throws -> ExitSignal {
        let exit = ExitSignal()
        process.terminationHandler = { _ in exit.fire() }
        try process.run()
        return exit
    }

    /// GUI-launched apps inherit a minimal PATH without `/opt/homebrew/bin`; yt-dlp needs
    /// `ffmpeg`/`deno` etc. to be on PATH at runtime.
    static func augmentedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:\(existing)"
        return env
    }

    /// Runs a link fetch; a stall or an overrun comes back with the site and the installed version folded in.
    static func fetch(
        ytDlpPath: String,
        arguments: [String],
        run: YtDlpRun,
        watch: YtDlpRunner.Watch,
        site: String?,
        onLine: @escaping @Sendable (YtDlpLine) -> Void = { _ in }
    ) async throws -> YtDlpRunner.Output {
        do {
            return try await YtDlpRunner.run(ytDlpPath: ytDlpPath, arguments: arguments, run: run, watch: watch, onLine: onLine)
        } catch ParolaError.linkDownloadFailed(var failure) {
            failure.site = site
            guard failure.reason != .toolFailedToStart else { throw ParolaError.linkDownloadFailed(failure) }
            let version = await YtDlpVersion.installed(at: ytDlpPath)
            throw ParolaError.linkDownloadFailed(failure.noting(installedVersion: version, now: Date()))
        }
    }

    /// Asks the installed yt-dlp for its version only once a run has failed, so a clean run pays nothing for it.
    static func failure(
        exitStatus: Int32,
        stderr: String,
        stdout: String,
        ytDlpPath: String,
        site: String?
    ) async -> LinkDownloadFailure {
        let version = await YtDlpVersion.installed(at: ytDlpPath)
        return LinkDownloadFailure(
            exitStatus: exitStatus,
            stderr: stderr,
            stdout: stdout,
            installedVersion: version?.text,
            site: site,
            now: Date()
        )
    }
}

extension YtDlpVersion {
    /// Runs `yt-dlp --version`. Nil when it can't run, fails, or prints something that isn't a version.
    public static func installed(at path: String, timeoutSeconds: Int = 10) async -> YtDlpVersion? {
        guard let output = try? await YtDlpRunner.run(
            ytDlpPath: path, arguments: ["--version"], run: .versionCheck, watch: .wallClock(seconds: timeoutSeconds)
        ), output.status == 0 else { return nil }
        return YtDlpVersion(output.stdoutText)
    }
}

/// Fired by the termination handler `YouTubeProcess.start` installs; waiters that arrive late return at once.
final class ExitSignal: Sendable {
    private struct State {
        var exited = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func fire() {
        let waiters = state.withLock { state in
            state.exited = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let exited = state.withLock { state in
                if !state.exited { state.waiters.append(continuation) }
                return state.exited
            }
            if exited { continuation.resume() }
        }
    }
}

#endif
