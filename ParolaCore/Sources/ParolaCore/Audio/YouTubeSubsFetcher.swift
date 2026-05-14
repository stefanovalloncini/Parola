import Foundation

/// Fetches existing YouTube captions via `yt-dlp` and parses them into a ``Transcript``.
/// Much faster than transcribing — Whisper isn't run at all.
///
/// Requires `yt-dlp` on `$PATH`. Common install: `brew install yt-dlp`.
public enum YouTubeSubsFetcher {
    public static func fetch(url: URL, preferLanguage: String? = nil) async throws -> Transcript {
        guard let ytDlp = findYtDlp() else {
            throw ParolaError.captureUnavailable(
                "yt-dlp not found on PATH. Install with: brew install yt-dlp"
            )
        }

        let workingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-yt-subs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingDir) }

        let outputTemplate = workingDir.appendingPathComponent("%(id)s").path
        let langList = preferLanguage ?? "en,en-US,en-GB"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytDlp)
        process.arguments = [
            "--write-subs",
            "--write-auto-subs",
            "--skip-download",
            "--sub-format", "vtt",
            "--sub-lang", langList,
            "--no-playlist",
            "-o", outputTemplate,
            url.absoluteString,
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do { try process.run() } catch {
            throw ParolaError.captureUnavailable("Could not launch yt-dlp: \(error.localizedDescription)")
        }
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let detail = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ParolaError.captureUnavailable("yt-dlp failed: \(detail)")
        }

        let vttFiles = (try? FileManager.default.contentsOfDirectory(at: workingDir, includingPropertiesForKeys: nil)) ?? []
        guard let chosen = pickVtt(from: vttFiles, preferLanguage: preferLanguage) else {
            throw ParolaError.captureUnavailable("This video has no subtitles available. Transcribe with Whisper instead.")
        }

        var transcript = try VttImporter.parse(contentsOf: chosen)
        transcript.modelName = chosen.lastPathComponent.contains(".auto.") ? "youtube-auto-subs" : "youtube-subs"
        transcript.sourceURL = url
        return transcript
    }

    static func pickVtt(from files: [URL], preferLanguage: String?) -> URL? {
        let vtts = files.filter { $0.pathExtension == "vtt" }
        if let lang = preferLanguage,
           let exact = vtts.first(where: { $0.lastPathComponent.contains(".\(lang).") }) {
            return exact
        }
        if let manual = vtts.first(where: { !$0.lastPathComponent.contains(".auto.") }) {
            return manual
        }
        return vtts.first
    }

    private static func findYtDlp() -> String? {
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
}
