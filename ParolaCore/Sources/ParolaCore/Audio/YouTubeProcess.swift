#if os(macOS)
import Foundation

enum YouTubeProcess {
    static func waitWithTimeout(_ process: Process, seconds: Int) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await waitForExit(process) }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                process.terminate()
                throw ParolaError.captureUnavailable("yt-dlp exceeded \(seconds)s timeout")
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private static func waitForExit(_ process: Process) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                process.terminationHandler = { _ in cont.resume() }
            }
        } onCancel: {
            process.terminate()
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
#endif
