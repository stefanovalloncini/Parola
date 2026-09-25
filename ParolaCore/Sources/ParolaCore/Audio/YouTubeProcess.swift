#if os(macOS)
import Foundation
import os

/// What a yt-dlp run is for, so a timeout in the log says which one stalled.
enum YtDlpRun: String, LogSafe {
    case download
    case captions
    case durationProbe
    case versionCheck

    var logToken: String { rawValue }
}

enum YouTubeProcess {
    /// Launches `process` with its exit signal wired up first, so a quick exit can't slip past the wait.
    static func start(_ process: Process) throws -> ExitSignal {
        let exit = ExitSignal()
        process.terminationHandler = { _ in exit.fire() }
        try process.run()
        return exit
    }

    static func waitWithTimeout(
        _ process: Process,
        exit: ExitSignal,
        seconds: Int,
        run: YtDlpRun,
        clock: any Clock<Duration> = ContinuousClock()
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await waitForExit(process, exit: exit)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds), clock: clock)
                if process.isRunning { process.terminate() }
                ParolaLog.error(.youtube, "yt-dlp \(run) timed out after \(seconds)s")
                throw ParolaError.linkDownloadFailed(LinkDownloadFailure(reason: .timedOut(seconds: seconds)))
            }
            try await group.next()
            group.cancelAll()
        }
    }

    /// Off the launching thread, `waitUntilExit()` can block for good on a notification queued to that thread's run loop, so this waits on the handler `start` installed.
    private static func waitForExit(_ process: Process, exit: ExitSignal) async {
        await withTaskCancellationHandler {
            await exit.wait()
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    static func findYtDlp() -> String? {
        for candidate in ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/usr/bin/yt-dlp"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        let env = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in env.split(separator: ":") {
            let candidate = "\(dir)/yt-dlp"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// GUI-launched apps inherit a minimal PATH without `/opt/homebrew/bin`; yt-dlp needs
    /// `ffmpeg`/`deno` etc. to be on PATH at runtime.
    static func augmentedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:\(existing)"
        return env
    }

    /// Waits out a download; a timeout comes back with the site and the installed version folded in.
    static func waitForDownload(
        _ process: Process, exit: ExitSignal, seconds: Int, run: YtDlpRun, ytDlpPath: String, site: String?
    ) async throws {
        do {
            try await waitWithTimeout(process, exit: exit, seconds: seconds, run: run)
        } catch ParolaError.linkDownloadFailed(var failure) {
            failure.site = site
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.environment = YouTubeProcess.augmentedEnvironment()
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let drain = PipeDrain(pipe: stdout)
        guard let exit = try? YouTubeProcess.start(process) else { return nil }
        do {
            try await YouTubeProcess.waitWithTimeout(process, exit: exit, seconds: timeoutSeconds, run: .versionCheck)
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return YtDlpVersion(String(decoding: drain.data(), as: UTF8.self))
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

/// Drains a `Pipe`'s read side on a background task so the producing process never blocks
/// on a full pipe buffer (typically 64 KB). Read `data()` after the process exits.
///
/// Unchecked Sendable: the only mutable state is `buffer`, guarded by `lock` on every access.
final class PipeDrain: @unchecked Sendable {
    private let buffer = NSMutableData()
    private let lock = NSLock()
    private let didFinish = DispatchSemaphore(value: 0)

    init(pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] fh in
            let chunk = fh.availableData
            if chunk.isEmpty {
                fh.readabilityHandler = nil
                self?.didFinish.signal()
                return
            }
            guard let self else { return }
            self.lock.lock()
            self.buffer.append(chunk)
            self.lock.unlock()
        }
    }

    func data(timeout: DispatchTime = .now() + 2.0) -> Data {
        _ = didFinish.wait(timeout: timeout)
        lock.lock()
        defer { lock.unlock() }
        return Data(buffer)
    }
}
#endif
