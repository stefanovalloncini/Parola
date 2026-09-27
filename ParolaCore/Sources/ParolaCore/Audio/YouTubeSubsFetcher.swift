#if os(macOS)
import Foundation

/// Fetches existing YouTube captions via `yt-dlp` and parses them into a ``Transcript``.
/// Much faster than transcribing — Whisper isn't run at all.
///
/// Requires `yt-dlp` on `$PATH`. Common install: `brew install yt-dlp`.
public struct YouTubeSubsResult: Sendable {
    public let transcript: Transcript
    public let metadata: LinkMetadata

    public var videoTitle: String? { metadata.title }
}

public enum YouTubeSubsFetcher {
    public static func fetch(url: URL, preferLanguage: String? = nil) async throws -> Transcript {
        try await fetchWithTitle(url: url, preferLanguage: preferLanguage).transcript
    }

    public static func fetchWithTitle(url: URL, preferLanguage: String? = nil) async throws -> YouTubeSubsResult {
        try await fetchWithTitle(url: url, preferLanguage: preferLanguage, ytDlpPath: YouTubeProcess.findYtDlp())
    }

    static func fetchWithTitle(url: URL, preferLanguage: String?, ytDlpPath: String?) async throws -> YouTubeSubsResult {
        let site = LinkDownloadFailure.site(for: url)
        guard let ytDlp = ytDlpPath else {
            throw ParolaError.linkDownloadFailed(LinkDownloadFailure(reason: .toolMissing, site: site))
        }

        let workingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parola-yt-subs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingDir) }

        let output = try await YouTubeProcess.fetch(
            ytDlpPath: ytDlp,
            arguments: arguments(
                url: url, preferLanguage: preferLanguage, outputTemplate: workingDir.appendingPathComponent("%(id)s").path
            ),
            run: .captions,
            watch: .wallClock(seconds: 120),
            site: site
        )
        try Task.checkCancellation()

        if output.status != 0 {
            let failure = await YouTubeProcess.failure(
                exitStatus: output.status, stderr: output.stderr, stdout: "", ytDlpPath: ytDlp, site: site
            )
            let error = ParolaError.linkDownloadFailed(failure)
            ParolaLog.error(.youtube, "yt-dlp exited with status \(Int(output.status))", [.error: .error(error)])
            throw error
        }

        let vttFiles = (try? FileManager.default.contentsOfDirectory(at: workingDir, includingPropertiesForKeys: nil)) ?? []
        guard var transcript = try captions(from: vttFiles, preferLanguage: preferLanguage) else {
            throw ParolaError.linkDownloadFailed(LinkDownloadFailure(reason: .noCaptions, site: site))
        }
        let metadata = output.metadata ?? LinkMetadata()
        transcript.sourceURL = metadata.webpageURL ?? url
        return YouTubeSubsResult(transcript: transcript, metadata: metadata)
    }

    static func arguments(url: URL, preferLanguage: String?, outputTemplate: String) -> [String] {
        [
            "--write-subs",
            "--write-auto-subs",
            "--skip-download",
            "--sub-format", "vtt",
            "--sub-langs", subtitleLanguages(preferLanguage),
            "--no-playlist",
            "--no-warnings",
            "--print", YtDlpLine.metadataTemplate,
            "-o", outputTemplate,
            url.absoluteString,
        ]
    }

    /// Every automatic language but `<lang>-orig` is a machine translation, so Auto asks for the original first.
    static func subtitleLanguages(_ preferLanguage: String?) -> String {
        guard let language = preferLanguage, !language.isEmpty else { return ".*-orig,en,en-US,en-GB" }
        return "\(language),\(language)-orig"
    }

    /// The track worth keeping from what yt-dlp wrote, parsed; speech-recognition captions lose their rolling repeats.
    static func captions(from files: [URL], preferLanguage: String?) throws -> Transcript? {
        let tracks = try files
            .filter { $0.pathExtension == "vtt" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map(CaptionTrack.init(contentsOf:))
        guard let chosen = pickTrack(from: tracks, preferLanguage: preferLanguage) else { return nil }
        var transcript = VttImporter.parse(chosen.raw)
        // A hand-made track keeps every cue: the overlap dedupe would drop short cues and words that only happen to repeat.
        if chosen.isSpeechRecognition {
            transcript = dedupeRollingCaptions(transcript)
        }
        transcript.modelName = chosen.isSpeechRecognition ? "youtube-auto-subs" : "youtube-subs"
        if !chosen.spokenLanguage.isEmpty { transcript.language = chosen.spokenLanguage }
        return transcript
    }

    /// A hand-made track in the spoken language, then the speech-recognition original, then whatever else came back.
    static func pickTrack(from tracks: [CaptionTrack], preferLanguage: String?) -> CaptionTrack? {
        let original = tracks.first(where: \.isOriginal)
        let spoken = preferLanguage.map(CaptionTrack.baseLanguage) ?? original?.spokenLanguage
        let handMade = tracks.filter { !$0.isSpeechRecognition }
        if let spoken, let match = handMade.first(where: { $0.spokenLanguage == spoken }) { return match }
        return original ?? handMade.first ?? tracks.first
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
}

/// yt-dlp names every track `<id>.<lang>.vtt`, hand-made or not, so the kind of track is read from the file itself.
struct CaptionTrack {
    /// yt-dlp's key for the track: `en`, `pt-BR`, or `it-orig` for YouTube's speech recognition in the spoken language.
    let language: String
    let raw: String
    let isSpeechRecognition: Bool

    init(contentsOf url: URL) throws {
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: ".")
        language = parts.count > 1 ? String(parts[parts.count - 1]) : ""
        raw = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        isSpeechRecognition = language.hasSuffix("-orig") || Self.looksLikeSpeechRecognition(raw)
    }

    var isOriginal: Bool { language.hasSuffix("-orig") }

    var spokenLanguage: String { Self.baseLanguage(language) }

    static func baseLanguage(_ key: String) -> String {
        String(key.split(separator: "-").first ?? "").lowercased()
    }

    /// Speech recognition times every word inline and ends each line with a 10 ms cue; a hand-made track never does both.
    static func looksLikeSpeechRecognition(_ raw: String) -> Bool {
        guard raw.contains(/<\d{2}:\d{2}:\d{2}\.\d{3}><c>/) else { return false }
        return raw.split(whereSeparator: \.isNewline).contains { line in
            guard line.contains("-->"), let cue = VttImporter.parseTimeLine(String(line)) else { return false }
            return abs(cue.end - cue.start - 0.01) < 0.002
        }
    }
}
#endif
