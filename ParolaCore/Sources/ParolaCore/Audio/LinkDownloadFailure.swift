import Foundation

/// Why yt-dlp couldn't fetch a link, in terms a person can act on, plus whether the installed yt-dlp
/// is old enough to be the likely cause.
public struct LinkDownloadFailure: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        case refused(httpStatus: Int?)
        case unavailable(Unavailability)
        case unreachable
        case timedOut(seconds: Int)
        case noCaptions
        case noAudio
        case unsupportedLink
        case toolMissing
        case toolFailedToStart
        /// yt-dlp's own error line, cleaned of its extractor prefix and command-line hints.
        case toolError(String)
        case toolExited(status: Int)
    }

    public enum Unavailability: String, Sendable, Equatable {
        case removed
        case privateVideo
        case membersOnly
        case ageRestricted
        case regionLocked
        case blocked
    }

    public var reason: Reason
    /// "YouTube" for a YouTube link, the bare host for any other site.
    public var site: String?
    public var ytDlpVersion: YtDlpVersion?
    public var ytDlpIsStale: Bool

    public init(reason: Reason, site: String? = nil, ytDlpVersion: YtDlpVersion? = nil, ytDlpIsStale: Bool = false) {
        self.reason = reason
        self.site = site
        self.ytDlpVersion = ytDlpVersion
        self.ytDlpIsStale = ytDlpIsStale
    }

    /// Reads a failed yt-dlp run. `installedVersion` is what `yt-dlp --version` printed, when it was asked.
    public init(
        exitStatus: Int32,
        stderr: String,
        stdout: String,
        installedVersion: String? = nil,
        site: String?,
        now: Date
    ) {
        let output = YtDlpOutput(stderr)
        let problem = output.errors.isEmpty ? output.plainTail.map { [$0] } ?? [] : output.errors
        let detail = problem.isEmpty ? YtDlpOutput(stdout).plainTail : problem.joined(separator: " ")
        let reason = detail.flatMap(Self.classify) ?? detail.map(Reason.toolError) ?? .toolExited(status: Int(exitStatus))
        self.init(reason: reason, site: site, ytDlpVersion: output.outdatedVersion, ytDlpIsStale: output.outdatedVersion != nil)
        self = noting(installedVersion: installedVersion.flatMap(YtDlpVersion.init), now: now)
    }

    /// Folds in the installed version, marking the failure stale when that version is past yt-dlp's age limit.
    public func noting(installedVersion: YtDlpVersion?, now: Date) -> LinkDownloadFailure {
        guard let installedVersion else { return self }
        var noted = self
        noted.ytDlpVersion = installedVersion
        noted.ytDlpIsStale = ytDlpIsStale || installedVersion.isStale(asOf: now)
        return noted
    }

    /// False when a second try can't change the answer: the video itself is off limits, or it has no captions.
    public var isWorthRetrying: Bool {
        switch reason {
        case .unavailable, .noCaptions, .unsupportedLink: return false
        default: return true
        }
    }

    public static func site(for url: URL) -> String? {
        if url.isYouTubeVideo { return "YouTube" }
        guard var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        for prefix in ["www.", "m."] where host.hasPrefix(prefix) {
            host.removeFirst(prefix.count)
        }
        return host
    }

    /// The English sentence the CLI prints; the app renders its own localized copy from the same fields.
    public var message: String {
        let hint = ytDlpIsStale ? staleSentence : freshHint
        return [headline, hint].compactMap { $0 }.joined(separator: " ")
    }

    private var headline: String {
        let site = self.site
        switch reason {
        case .refused(let status):
            let who = site ?? "The site"
            return status.map { "\(who) refused the download (HTTP \($0))." } ?? "\(who) refused the download."
        case .unavailable(.removed):
            return "This video can't be downloaded. It may have been removed."
        case .unavailable(.privateVideo):
            return "This video can't be downloaded because it's private."
        case .unavailable(.membersOnly):
            return "This video can't be downloaded because it's for channel members only."
        case .unavailable(.ageRestricted):
            return "This video can't be downloaded because it's age-restricted."
        case .unavailable(.regionLocked):
            return "This video can't be downloaded because it isn't available in your country."
        case .unavailable(.blocked):
            return "This video can't be downloaded because it's blocked on copyright grounds."
        case .unreachable:
            return site.map { "Couldn't reach \($0)." } ?? "Couldn't reach the site."
        case .timedOut(let seconds):
            return "The download didn't finish within \(seconds) seconds."
        case .noCaptions:
            return "This video has no captions. Transcribe it instead."
        case .noAudio:
            return "yt-dlp finished without saving any audio."
        case .unsupportedLink:
            return "yt-dlp can't download from this site."
        case .toolMissing:
            return "yt-dlp isn't installed. Install it with: brew install yt-dlp"
        case .toolFailedToStart:
            return "Parola couldn't start yt-dlp."
        case .toolError(let detail):
            return "yt-dlp failed: \(detail)"
        case .toolExited(let status):
            return "yt-dlp stopped with exit status \(status)."
        }
    }

    private var freshHint: String? {
        switch reason {
        case .refused: return "Try again later."
        case .unreachable, .timedOut: return "Check your internet connection and try again."
        default: return nil
        }
    }

    private var staleSentence: String {
        guard let ytDlpVersion else { return "Your yt-dlp is out of date — update it and try again." }
        return "Your yt-dlp (\(ytDlpVersion.text)) is out of date — update it and try again."
    }
}

extension LinkDownloadFailure {
    static func classify(_ detail: String) -> Reason? {
        let text = detail.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        func mentions(_ needles: [String]) -> Bool { needles.contains { text.contains($0) } }

        if mentions(["private video", "this video is private"]) { return .unavailable(.privateVideo) }
        if mentions(["members-only", "channel's members", "join this channel"]) { return .unavailable(.membersOnly) }
        if mentions(["confirm your age", "age-restricted", "age restricted", "inappropriate for some users"]) {
            return .unavailable(.ageRestricted)
        }
        if mentions(["in your country", "from your location", "geo restriction", "geo-restricted"]) {
            return .unavailable(.regionLocked)
        }
        if mentions(["copyright grounds", "copyright claim"]) { return .unavailable(.blocked) }
        let status = httpStatus(in: detail)
        if mentions([
            "not a bot", "captcha", "requested format is not available", "rate-limited",
            "this content isn't available, try again later",
        ]) {
            return .refused(httpStatus: status)
        }
        switch status {
        case 401, 403, 429: return .refused(httpStatus: status)
        case 404, 410: return .unavailable(.removed)
        default: break
        }
        if mentions(["video unavailable", "this video is unavailable", "this video is not available", "has been removed"]) {
            return .unavailable(.removed)
        }
        if mentions(networkMarkers) { return .unreachable }
        return nil
    }

    private static let networkMarkers = [
        "nodename nor servname", "failed to resolve", "name resolution", "getaddrinfo", "name or service not known",
        "timed out", "network is unreachable", "network is down", "no route to host", "connection refused",
        "connection reset", "connection aborted", "remote end closed connection", "max retries exceeded",
        "internet connection appears to be offline",
    ]

    private static func httpStatus(in text: String) -> Int? {
        guard let match = text.firstMatch(of: /HTTP Error (\d{3})/) else { return nil }
        return Int(match.1)
    }
}

extension LinkDownloadFailure: LogSafe {
    public var logToken: String {
        var token: String
        switch reason {
        case .refused(let status): token = status.map { "refused.\($0)" } ?? "refused"
        case .unavailable(let why): token = "unavailable.\(why.rawValue)"
        case .unreachable: token = "unreachable"
        case .timedOut: token = "timedOut"
        case .noCaptions: token = "noCaptions"
        case .noAudio: token = "noAudio"
        case .unsupportedLink: token = "unsupportedLink"
        case .toolMissing: token = "toolMissing"
        case .toolFailedToStart: token = "toolFailedToStart"
        case .toolError: token = "toolError"
        case .toolExited(let status): token = "toolExited.\(status)"
        }
        if let ytDlpVersion { token += ",yt-dlp.\(ytDlpVersion.logToken)" }
        if ytDlpIsStale { token += ",stale" }
        return token
    }
}

/// yt-dlp's stderr split into its ERROR and WARNING messages; a message's indented lines belong to it.
struct YtDlpOutput {
    private(set) var errors: [String] = []
    private(set) var warnings: [String] = []
    private(set) var plain: [String] = []

    init(_ text: String) {
        let stripped = text
            .replacingOccurrences(of: #"\x{1B}\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+(?=ERROR: )"#, with: "\n", options: .regularExpression)
        var blocks: [(kind: Kind, lines: [String])] = []
        for raw in stripped.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if line.first?.isWhitespace == true, !blocks.isEmpty {
                blocks[blocks.count - 1].lines.append(trimmed)
            } else if trimmed.hasPrefix("ERROR:") {
                blocks.append((.error, [String(trimmed.dropFirst("ERROR:".count))]))
            } else if trimmed.hasPrefix("WARNING:") {
                blocks.append((.warning, [String(trimmed.dropFirst("WARNING:".count))]))
            } else {
                blocks.append((.plain, [trimmed]))
            }
        }
        for block in blocks {
            let joined = block.lines.joined(separator: " ")
            switch block.kind {
            case .error:
                let cleaned = Self.cleaned(joined)
                if !cleaned.isEmpty, !errors.contains(cleaned) { errors.append(cleaned) }
            case .warning:
                warnings.append(Self.collapsed(joined))
            case .plain:
                plain.append(Self.collapsed(joined))
            }
        }
    }

    private enum Kind { case error, warning, plain }

    /// The last line a crash leaves behind, e.g. the exception under a Python traceback.
    var plainTail: String? {
        plain.last.map(Self.cleaned).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The version yt-dlp names when it warns that it's more than 90 days old.
    var outdatedVersion: YtDlpVersion? {
        for warning in warnings {
            guard let match = warning.firstMatch(of: /Your yt-dlp version \(([^)]+)\) is older than/) else { continue }
            if let version = YtDlpVersion(String(match.1)) { return version }
        }
        return nil
    }

    private static let cliHints = [
        "; please report this issue", " (caused by ", " Use --", ". Use --", " See http", " Also see ",
    ]

    static func cleaned(_ message: String) -> String {
        var text = collapsed(message)
        if let tag = text.firstMatch(of: /^\[[^\]]+\]\s+(?:[^\s:]+:\s+)?/) {
            text = String(text[tag.range.upperBound...])
        }
        if let cut = cliHints.compactMap({ text.range(of: $0)?.lowerBound }).min() {
            text = String(text[..<cut])
        }
        text = text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ";,:")))
        guard let first = text.first else { return "" }
        text = first.uppercased() + text.dropFirst()
        if let last = text.last, !".!?".contains(last) { text += "." }
        return text
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
