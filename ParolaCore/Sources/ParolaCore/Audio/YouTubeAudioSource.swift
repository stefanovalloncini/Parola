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
        if path.hasPrefix("/live/") { return true }
        return false
    }

    /// True if this URL is on a host that yt-dlp can fetch from.
    var isYtDlpSupported: Bool {
        if isYouTubeVideo { return true }
        guard let host = host?.lowercased() else { return false }
        let suffixes = [
            "vimeo.com",
            "twitter.com", "x.com", "t.co",
            "tiktok.com",
            "soundcloud.com",
            "facebook.com", "fb.watch",
            "instagram.com",
            "twitch.tv",
            "reddit.com", "v.redd.it",
        ]
        return suffixes.contains { host == $0 || host.hasSuffix(".\($0)") }
    }
}

#if os(macOS)

/// Audio source that downloads a YouTube video's audio via `yt-dlp`.
///
/// Requires `yt-dlp` on `$PATH`. Common install: `brew install yt-dlp`.
public actor YouTubeAudioSource: AudioSource {
    public let url: URL

    private let workingDir: URL
    private let timeoutSeconds: Int
    private var downloadedURL: URL?
    private var runningProcess: Process?

    public init(url: URL, timeoutSeconds: Int = 120, features: FeatureSet = .resolve()) throws {
        try features.require(.youtube)
        guard url.isYtDlpSupported else {
            throw ParolaError.captureUnavailable("URL not supported by yt-dlp: \(url.absoluteString)")
        }
        self.url = url
        self.timeoutSeconds = timeoutSeconds
        self.workingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-yt-\(UUID().uuidString)")
    }

    public func prepare() async throws -> URL {
        if let downloadedURL { return downloadedURL }

        guard let ytDlp = YouTubeProcess.findYtDlp() else {
            throw ParolaError.captureUnavailable(
                "yt-dlp not found on PATH. install with: brew install yt-dlp"
            )
        }

        try FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)
        let target = try await downloadAudio(ytDlpPath: ytDlp)
        downloadedURL = target
        return target
    }

    public func cancel() async {
        if let process = runningProcess, process.isRunning {
            process.terminate()
        }
        runningProcess = nil
        try? FileManager.default.removeItem(at: workingDir)
        downloadedURL = nil
    }

    /// Best-effort duration in seconds. Probes via `yt-dlp --print duration` without downloading.
    public func estimatedDuration() async -> Double? {
        guard let ytDlp = YouTubeProcess.findYtDlp() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytDlp)
        process.arguments = [
            "--no-playlist",
            "--no-warnings",
            "--skip-download",
            "--print", "duration",
            url.absoluteString,
        ]
        process.environment = YouTubeProcess.augmentedEnvironment()
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        let drain = PipeDrain(pipe: stdout)
        do { try process.run() } catch { return nil }
        try? await YouTubeProcess.waitWithTimeout(process, seconds: 20)
        guard process.terminationStatus == 0 else { return nil }
        let raw = String(decoding: drain.data(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(raw)
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

        process.environment = YouTubeProcess.augmentedEnvironment()

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let outDrain = PipeDrain(pipe: stdout)
        let errDrain = PipeDrain(pipe: stderr)

        do {
            try process.run()
        } catch {
            throw ParolaError.captureUnavailable("could not launch yt-dlp: \(error.localizedDescription)")
        }
        runningProcess = process
        defer { runningProcess = nil }

        try await YouTubeProcess.waitWithTimeout(process, seconds: timeoutSeconds)

        let outText = String(decoding: outDrain.data(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let errText = String(decoding: errDrain.data(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            throw ParolaError.captureUnavailable("yt-dlp failed: \(errText.isEmpty ? outText : errText)")
        }

        let path = outText.components(separatedBy: "\n").last ?? outText
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            throw ParolaError.captureUnavailable("yt-dlp didn't report a usable file path")
        }
        return URL(fileURLWithPath: path)
    }

}

#endif
