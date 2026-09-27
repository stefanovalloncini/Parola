import Foundation
import os

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

/// Audio source that downloads a video's audio via `yt-dlp`.
///
/// Requires `yt-dlp` on `$PATH`. Common install: `brew install yt-dlp`.
public actor YouTubeAudioSource: AudioSource {
    public let url: URL

    nonisolated let workingDir: URL
    private let ytDlpPath: String?
    private let limits: YtDlpRunner.ProgressLimits
    private var fetched: FetchedMedia?

    public init(url: URL, features: FeatureSet = .resolve()) throws {
        try self.init(url: url, features: features, ytDlpPath: YouTubeProcess.findYtDlp(), limits: .init())
    }

    init(url: URL, features: FeatureSet, ytDlpPath: String?, limits: YtDlpRunner.ProgressLimits) throws {
        try features.require(.youtube)
        guard url.isYtDlpSupported else {
            ParolaLog.notice(.youtube, "URL is not on a host yt-dlp can fetch from")
            throw ParolaError.linkDownloadFailed(LinkDownloadFailure(reason: .unsupportedLink))
        }
        self.url = url
        self.ytDlpPath = ytDlpPath
        self.limits = limits
        self.workingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(LinkDownloadFolders.prefix)\(UUID().uuidString)")
    }

    public func prepare() async throws -> URL {
        try await fetch().fileURL
    }

    public func fetch(progress: @escaping @Sendable (LinkFetchEvent) -> Void = { _ in }) async throws -> FetchedMedia {
        if let fetched { return fetched }
        guard let ytDlp = ytDlpPath else {
            throw ParolaError.linkDownloadFailed(LinkDownloadFailure(reason: .toolMissing, site: site))
        }
        try FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)
        do {
            let media = try await download(ytDlpPath: ytDlp, progress: progress)
            fetched = media
            return media
        } catch {
            try? FileManager.default.removeItem(at: workingDir)
            throw error
        }
    }

    private func download(
        ytDlpPath ytDlp: String, progress: @escaping @Sendable (LinkFetchEvent) -> Void
    ) async throws -> FetchedMedia {
        // Progress comes on stdout and post-processing on stderr, so a late progress line mustn't take the bar backwards.
        let processing = OSAllocatedUnfairLock(initialState: false)
        let output = try await YouTubeProcess.fetch(
            ytDlpPath: ytDlp,
            arguments: Self.arguments(url: url, outputTemplate: workingDir.appendingPathComponent("audio.%(ext)s").path),
            run: .download,
            watch: .progress(limits),
            site: site
        ) { line in
            guard let event = line.event else { return }
            let stale = processing.withLock { seen in
                if case .processing = event { seen = true }
                if case .downloading = event { return seen }
                return false
            }
            if !stale { progress(event) }
        }
        try Task.checkCancellation()

        guard output.status == 0 else {
            let failure = await YouTubeProcess.failure(
                exitStatus: output.status, stderr: output.stderr, stdout: output.stdoutText, ytDlpPath: ytDlp, site: site
            )
            let error = ParolaError.linkDownloadFailed(failure)
            ParolaLog.error(.youtube, "yt-dlp exited with status \(Int(output.status))", [.error: .error(error)])
            throw error
        }
        guard let path = output.filePath, FileManager.default.fileExists(atPath: path) else {
            throw ParolaError.linkDownloadFailed(LinkDownloadFailure(reason: .noAudio, site: site))
        }
        return FetchedMedia(
            fileURL: URL(fileURLWithPath: path), metadata: output.metadata ?? LinkMetadata(), workingDirectory: workingDir
        )
    }

    public func cancel() async {
        try? FileManager.default.removeItem(at: workingDir)
        fetched = nil
    }

    /// The m4a stream when the site has one, so yt-dlp only remuxes it; anything else is converted to m4a.
    static func arguments(url: URL, outputTemplate: String) -> [String] {
        [
            "-f", "bestaudio[ext=m4a]/bestaudio/best",
            "-x",
            "--audio-format", "m4a",
            "--audio-quality", "0",
            "--no-playlist",
            "--socket-timeout", "30",
            "--progress",
            "--newline",
            "--progress-delta", "1",
            "--progress-template", YtDlpLine.progressTemplate,
            "--progress-template", YtDlpLine.processingTemplate,
            "--print", YtDlpLine.metadataTemplate,
            "--print", YtDlpLine.fileTemplate,
            "-o", outputTemplate,
            url.absoluteString,
        ]
    }

    private var site: String? { LinkDownloadFailure.site(for: url) }
}

#endif
