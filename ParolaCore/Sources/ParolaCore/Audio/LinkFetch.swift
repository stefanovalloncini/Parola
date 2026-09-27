#if os(macOS)
import Foundation

/// What yt-dlp says about the video a link points at, read from the same run that downloads it.
public struct LinkMetadata: Sendable, Equatable {
    public var title: String?
    /// The page yt-dlp resolved the link to, e.g. `https://www.youtube.com/watch?v=…` for a `youtu.be` link.
    public var webpageURL: URL?
    public var id: String?
    public var duration: Double?

    public init(title: String? = nil, webpageURL: URL? = nil, id: String? = nil, duration: Double? = nil) {
        self.title = title
        self.webpageURL = webpageURL
        self.id = id
        self.duration = duration
    }

    init(json: String) {
        let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            title: title?.isEmpty == false ? title : nil,
            webpageURL: (object["webpage_url"] as? String).flatMap(URL.init(string:)),
            id: object["id"] as? String,
            duration: (object["duration"] as? NSNumber)?.doubleValue
        )
    }
}

/// How a link download is getting on, as it happens.
public enum LinkFetchEvent: Sendable, Equatable {
    case metadata(LinkMetadata)
    /// Nil when the site doesn't say how big the file is.
    case downloading(fraction: Double?)
    /// yt-dlp is converting or remuxing what it downloaded, which reports no progress of its own.
    case processing
}

/// A link's audio, downloaded to a local file. The download's working folder belongs to whoever holds this, and
/// ``discard()`` removes it once the file has been used or moved into the library.
public struct FetchedMedia: Sendable {
    public let fileURL: URL
    public let metadata: LinkMetadata
    /// Nil when the file isn't the fetch's to delete, like a test fixture.
    public let workingDirectory: URL?

    public init(fileURL: URL, metadata: LinkMetadata = LinkMetadata(), workingDirectory: URL? = nil) {
        self.fileURL = fileURL
        self.metadata = metadata
        self.workingDirectory = workingDirectory
    }

    public func discard() {
        guard let workingDirectory else { return }
        try? FileManager.default.removeItem(at: workingDirectory)
    }
}

/// Every link fetch works in a `parola-yt-…` folder under the temporary directory.
public enum LinkDownloadFolders {
    public static let prefix = "parola-yt-"

    /// A fetch cut short by a crash or a kill leaves its folder behind; a day on, nothing can still be using it.
    @discardableResult
    public static func removeStale(
        in directory: URL = FileManager.default.temporaryDirectory,
        olderThan age: TimeInterval = 86_400,
        now: Date = Date()
    ) -> Int {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles
        )) ?? []
        var removed = 0
        for folder in folders where folder.lastPathComponent.hasPrefix(prefix) {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, now.timeIntervalSince(modified) > age else { continue }
            if (try? fm.removeItem(at: folder)) != nil { removed += 1 }
        }
        return removed
    }
}

/// The lines Parola asks yt-dlp to print, each behind its own marker so they never mix with yt-dlp's own output.
enum YtDlpLine: Equatable {
    case metadata(LinkMetadata)
    case downloaded(bytes: Double, total: Double?)
    case processing
    case file(String)

    static let metadataTemplate = "before_dl:[PAROLA_META] %(.{title,webpage_url,id,duration})j"
    static let progressTemplate =
        "download:[PAROLA_P] %(progress.downloaded_bytes)s %(progress.total_bytes,progress.total_bytes_estimate)s"
    static let processingTemplate = "postprocess:[PAROLA_PP] %(progress.status)s %(progress.postprocessor)s"
    static let fileTemplate = "after_move:[PAROLA_FILE] %(filepath)s"

    init?(_ raw: String) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rest = Self.payload(of: line, marker: "[PAROLA_META]") {
            self = .metadata(LinkMetadata(json: rest))
        } else if let rest = Self.payload(of: line, marker: "[PAROLA_P]") {
            let fields = rest.split(separator: " ")
            guard let bytes = fields.first.flatMap({ Double($0) }) else { return nil }
            let total = fields.dropFirst().first.flatMap { Double($0) }.flatMap { $0 > 0 ? $0 : nil }
            self = .downloaded(bytes: bytes, total: total)
        } else if Self.payload(of: line, marker: "[PAROLA_PP]") != nil {
            self = .processing
        } else if let rest = Self.payload(of: line, marker: "[PAROLA_FILE]"), !rest.isEmpty {
            self = .file(rest)
        } else {
            return nil
        }
    }

    var event: LinkFetchEvent? {
        switch self {
        case .metadata(let metadata): return .metadata(metadata)
        case .downloaded(let bytes, let total): return .downloading(fraction: total.map { min(1, max(0, bytes / $0)) })
        case .processing: return .processing
        case .file: return nil
        }
    }

    private static func payload(of line: String, marker: String) -> String? {
        guard line.hasPrefix(marker) else { return nil }
        return line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
    }
}
#endif
