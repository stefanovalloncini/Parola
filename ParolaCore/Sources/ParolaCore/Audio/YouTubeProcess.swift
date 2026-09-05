#if os(macOS)
import Foundation

enum YouTubeProcess {
    static func waitWithTimeout(
        _ process: Process,
        seconds: Int,
        clock: any Clock<Duration> = ContinuousClock()
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await waitForExit(process)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds), clock: clock)
                if process.isRunning { process.terminate() }
                ParolaLog.error(.youtube, "yt-dlp timed out after \(seconds)s")
                throw ParolaError.captureUnavailable("yt-dlp exceeded \(seconds)s timeout")
            }
            try await group.next()
            group.cancelAll()
        }
    }

    /// `Process.waitUntilExit()` is blocking. Running it on a detached task moves the block
    /// off the cooperative pool. Cancellation is honoured by the surrounding task group:
    /// the timeout branch calls `terminate()` which unblocks `waitUntilExit()`.
    private static func waitForExit(_ process: Process) async {
        let task = Task.detached(priority: .utility) {
            process.waitUntilExit()
        }
        await withTaskCancellationHandler {
            await task.value
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
