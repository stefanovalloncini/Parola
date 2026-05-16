import Foundation

public extension URL {
    /// True if this URL points at a YouTube video page.
    var isYouTubeVideo: Bool {
        guard let host = host?.lowercased() else { return false }
        if host == "youtu.be" || host == "www.youtu.be" {
            return !path.isEmpty && path != "/"
        }
        let youtubeHosts: Set<String> = ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"]
        guard youtubeHosts.contains(host) else { return false }
        if path.hasPrefix("/watch") { return true }
        if path.hasPrefix("/shorts/") { return true }
        if path.hasPrefix("/embed/") { return true }
        return false
    }
}

#if os(macOS)

/// Audio source that downloads a YouTube video's audio via `yt-dlp`.
///
/// Requires `yt-dlp` on `$PATH`. Common install: `brew install yt-dlp`.
// Justification: downloadedURL is written once per instance during a single prepare() call; callers serialize access by awaiting it.
public final class YouTubeAudioSource: AudioSource, @unchecked Sendable {
    public let url: URL

    private let workingDir: URL
    private var downloadedURL: URL?

    public init(url: URL) {
        self.url = url
        self.workingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-yt-\(UUID().uuidString)")
    }

    public func prepare() async throws -> URL {
        if let downloadedURL { return downloadedURL }

        guard let ytDlp = Self.findYtDlp() else {
            throw ParolaError.captureUnavailable(
                "yt-dlp not found on PATH. Install with: brew install yt-dlp"
            )
        }

        try FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)
        let target = try await downloadAudio(ytDlpPath: ytDlp)
        downloadedURL = target
        return target
    }

    public func cancel() async {
        try? FileManager.default.removeItem(at: workingDir)
        downloadedURL = nil
    }

    private func downloadAudio(ytDlpPath: String) async throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytDlpPath)
        let outputTemplate = workingDir.appendingPathComponent("audio.%(ext)s").path
        process.arguments = [
            "-x",
            "--audio-format", "m4a",
            "--audio-quality", "0",
            "--no-playlist",
            "-o", outputTemplate,
            "--print", "after_move:filepath",
            url.absoluteString,
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw ParolaError.captureUnavailable("Could not launch yt-dlp: \(error.localizedDescription)")
        }

        try await Self.waitWithTimeout(process, seconds: 120)

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let outText = String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let errText = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            throw ParolaError.captureUnavailable("yt-dlp failed: \(errText.isEmpty ? outText : errText)")
        }

        let path = outText.components(separatedBy: "\n").last ?? outText
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            throw ParolaError.captureUnavailable("yt-dlp didn't report a usable file path.")
        }
        return URL(fileURLWithPath: path)
    }

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

    private static func findYtDlp() -> String? {
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
}

#endif
