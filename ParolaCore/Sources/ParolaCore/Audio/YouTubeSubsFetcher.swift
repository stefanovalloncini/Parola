#if os(macOS)
import Foundation

/// Fetches existing YouTube captions via `yt-dlp` and parses them into a ``Transcript``.
/// Much faster than transcribing — Whisper isn't run at all.
///
/// Requires `yt-dlp` on `$PATH`. Common install: `brew install yt-dlp`.
public struct YouTubeSubsResult: Sendable {
    public let transcript: Transcript
    public let videoTitle: String?
}

public enum YouTubeSubsFetcher {
    public static func fetch(url: URL, preferLanguage: String? = nil) async throws -> Transcript {
        try await fetchWithTitle(url: url, preferLanguage: preferLanguage).transcript
    }

    public static func fetchWithTitle(url: URL, preferLanguage: String? = nil) async throws -> YouTubeSubsResult {
        let site = LinkDownloadFailure.site(for: url)
        guard let ytDlp = YouTubeProcess.findYtDlp() else {
            throw ParolaError.linkDownloadFailed(LinkDownloadFailure(reason: .toolMissing, site: site))
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
            "--no-warnings",
            "--print", "before_dl:[PAROLA_TITLE] %(title)s",
            "-o", outputTemplate,
            url.absoluteString,
        ]
        process.environment = YouTubeProcess.augmentedEnvironment()

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let outDrain = PipeDrain(pipe: stdout)
        let errDrain = PipeDrain(pipe: stderr)

        let exit: ExitSignal
        do { exit = try YouTubeProcess.start(process) } catch {
            ParolaLog.error(.youtube, "yt-dlp could not be launched", [.error: .error(error)])
            throw ParolaError.linkDownloadFailed(LinkDownloadFailure(reason: .toolFailedToStart, site: site))
        }
        try await YouTubeProcess.waitForDownload(
            process, exit: exit, seconds: 120, run: .captions, ytDlpPath: ytDlp, site: site
        )
        try Task.checkCancellation()

        let stdoutText = String(decoding: outDrain.data(), as: UTF8.self)

        if process.terminationStatus != 0 {
            let failure = await YouTubeProcess.failure(
                exitStatus: process.terminationStatus,
                stderr: String(decoding: errDrain.data(), as: UTF8.self),
                stdout: "",
                ytDlpPath: ytDlp,
                site: site
            )
            let error = ParolaError.linkDownloadFailed(failure)
            ParolaLog.error(.youtube, "yt-dlp exited with status \(Int(process.terminationStatus))", [.error: .error(error)])
            throw error
        }

        let videoTitle = parseTitle(from: stdoutText)

        let vttFiles = (try? FileManager.default.contentsOfDirectory(at: workingDir, includingPropertiesForKeys: nil)) ?? []
        guard let chosen = pickVtt(from: vttFiles, preferLanguage: preferLanguage) else {
            throw ParolaError.linkDownloadFailed(LinkDownloadFailure(reason: .noCaptions, site: site))
        }

        let isAuto = chosen.lastPathComponent.contains(".auto.")
        var transcript = try VttImporter.parse(contentsOf: chosen)
        // Only auto-generated captions roll; running the overlap dedupe on a manual/uploader
        // track drops legitimate short cues and strips words that only coincidentally repeat.
        if isAuto {
            transcript = dedupeRollingCaptions(transcript)
        }
        transcript.modelName = isAuto ? "youtube-auto-subs" : "youtube-subs"
        transcript.sourceURL = url
        return YouTubeSubsResult(transcript: transcript, videoTitle: videoTitle)
    }

    /// YouTube's auto-generated captions roll: each cue shows two lines where the first line
    /// repeats the previous cue's second line. After VTT parsing each cue's lines are joined,
    /// so consecutive segments overlap at the boundary like:
    ///     prev: "hello world how"
    ///     curr: "world how are you"
    /// This strips the overlap from each segment, leaving only the new words.
    static func dedupeRollingCaptions(_ transcript: Transcript) -> Transcript {
        var output: [TranscriptSegment] = []
        for segment in transcript.segments {
            // Drop the ~10ms "finalisation" cues YouTube emits between rolling cues.
            if segment.end - segment.start < 0.1 { continue }
            let trimmed = segment.text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if let last = output.last {
                let lastTrim = last.text.trimmingCharacters(in: .whitespaces)
                if lastTrim.hasPrefix(trimmed) {
                    continue
                }
                if let suffix = strippingOverlap(of: lastTrim, from: trimmed), !suffix.isEmpty {
                    output.append(TranscriptSegment(
                        id: output.count,
                        start: last.end,
                        end: segment.end,
                        text: suffix
                    ))
                    continue
                }
            }
            output.append(TranscriptSegment(
                id: output.count,
                start: segment.start,
                end: segment.end,
                text: trimmed
            ))
        }
        var updated = transcript
        updated.segments = output
        updated.durationSeconds = output.last?.end ?? transcript.durationSeconds
        return updated
    }

    /// If a suffix of `previous` (word-aligned) matches a prefix of `current`, returns
    /// `current` with that overlap removed. Returns nil if there's no usable overlap.
    static func strippingOverlap(of previous: String, from current: String) -> String? {
        let prevWords = previous.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let currWords = current.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !prevWords.isEmpty, !currWords.isEmpty else { return nil }

        let maxOverlap = min(prevWords.count, currWords.count)
        var overlap = 0
        for k in stride(from: maxOverlap, through: 1, by: -1) {
            if Array(prevWords.suffix(k)) == Array(currWords.prefix(k)) {
                overlap = k
                break
            }
        }
        guard overlap > 0 else { return nil }
        return currWords.dropFirst(overlap).joined(separator: " ")
    }

    static func parseTitle(from stdout: String) -> String? {
        for raw in stdout.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let range = line.range(of: "[PAROLA_TITLE]") {
                let title = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { return String(title) }
            }
        }
        return nil
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

}
#endif
