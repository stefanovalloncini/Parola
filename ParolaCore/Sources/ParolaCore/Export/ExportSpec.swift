import Foundation

/// The three shapes an export can take. A style owns the formats that can render it.
public enum ExportStyle: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case transcript
    case subtitles
    case segments

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .transcript: return "Transcript"
        case .subtitles: return "Subtitles"
        case .segments: return "Segments"
        }
    }

    public var formats: [ExportFormat] {
        switch self {
        case .transcript: return [.txt, .md, .html, .docx, .pdf, .fcpxml]
        case .subtitles: return [.srt, .vtt, .lrc]
        case .segments: return [.json, .jsonl, .csv, .tsv]
        }
    }

    public static func style(for format: ExportFormat) -> ExportStyle {
        allCases.first { $0.formats.contains(format) } ?? .transcript
    }
}

/// How segments are batched before a format renders them.
public enum ExportGrouping: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case none
    case speakerParagraphs

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "Segment per line"
        case .speakerParagraphs: return "Paragraph per speaker"
        }
    }

    /// Merges runs of segments that share a speaker into one segment, keeping the first start and the last end.
    public func apply(to segments: [TranscriptSegment]) -> [TranscriptSegment] {
        guard self == .speakerParagraphs else { return segments }
        var merged: [TranscriptSegment] = []
        for segment in segments {
            guard var previous = merged.last,
                  Format.presentationSpeakerLabel(previous.speaker) == Format.presentationSpeakerLabel(segment.speaker)
            else {
                merged.append(segment)
                continue
            }
            let head = previous.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            previous.text = [head, tail].filter { !$0.isEmpty }.joined(separator: " ")
            previous.end = max(previous.end, segment.end)
            if previous.words != nil || segment.words != nil {
                previous.words = (previous.words ?? []) + (segment.words ?? [])
            }
            merged[merged.count - 1] = previous
        }
        return merged
    }
}

/// Which language of a translated transcript an export writes.
public enum ExportContent: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case original
    case translation
    case both

    public var id: String { rawValue }
}

/// Everything the formats can be told about an export. Each format reads the fields that apply to it.
public struct ExportOptions: Sendable, Codable, Hashable {
    public var timestamps: Bool
    public var endTimestamps: Bool
    public var milliseconds: Bool
    public var speakers: Bool
    public var captionLength: CaptionLength
    public var htmlTheme: HtmlExportTheme
    public var grouping: ExportGrouping
    public var content: ExportContent

    public init(
        timestamps: Bool = false,
        endTimestamps: Bool = false,
        milliseconds: Bool = false,
        speakers: Bool = true,
        captionLength: CaptionLength = .none,
        htmlTheme: HtmlExportTheme = .light,
        grouping: ExportGrouping = .none,
        content: ExportContent = .original
    ) {
        self.timestamps = timestamps
        self.endTimestamps = endTimestamps
        self.milliseconds = milliseconds
        self.speakers = speakers
        self.captionLength = captionLength
        self.htmlTheme = htmlTheme
        self.grouping = grouping
        self.content = content
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamps = try c.decodeIfPresent(Bool.self, forKey: .timestamps) ?? false
        endTimestamps = try c.decodeIfPresent(Bool.self, forKey: .endTimestamps) ?? false
        milliseconds = try c.decodeIfPresent(Bool.self, forKey: .milliseconds) ?? false
        speakers = try c.decodeIfPresent(Bool.self, forKey: .speakers) ?? true
        captionLength = try c.decodeIfPresent(CaptionLength.self, forKey: .captionLength) ?? .none
        htmlTheme = try c.decodeIfPresent(HtmlExportTheme.self, forKey: .htmlTheme) ?? .light
        grouping = try c.decodeIfPresent(ExportGrouping.self, forKey: .grouping) ?? .none
        content = try c.decodeIfPresent(ExportContent.self, forKey: .content) ?? .original
    }

    /// The stamp a text format puts in front of a segment, or nil when timestamps are off.
    public func timestampLabel(start: Double, end: Double) -> String? {
        guard timestamps else { return nil }
        guard endTimestamps else { return clock(start) }
        return "\(clock(start)) → \(clock(end))"
    }

    private func clock(_ seconds: Double) -> String {
        milliseconds
            ? Format.subtitleTimestamp(seconds, msSeparator: ".")
            : Format.timestampHHMMSS(seconds)
    }
}

/// One export, fully described: what to render, in which format, with which options.
public struct ExportSpec: Sendable, Codable, Hashable {
    public var style: ExportStyle
    public var format: ExportFormat
    public var options: ExportOptions

    public init(style: ExportStyle, format: ExportFormat, options: ExportOptions = ExportOptions()) {
        self.style = style
        self.format = format
        self.options = options
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(ExportFormat.self, forKey: .format)
        style = try c.decodeIfPresent(ExportStyle.self, forKey: .style) ?? ExportStyle.style(for: format)
        options = try c.decodeIfPresent(ExportOptions.self, forKey: .options) ?? ExportSpec.standard(for: format).options
    }

    /// What a format exports as when nothing has been configured.
    public static func standard(for format: ExportFormat) -> ExportSpec {
        var options = ExportOptions()
        // HTML has always carried timestamps, and a subtitle cue has always left the speaker out.
        options.timestamps = format == .html
        options.speakers = !(format == .srt || format == .vtt)
        return ExportSpec(style: ExportStyle.style(for: format), format: format, options: options)
    }

    /// The same export in another format, moved to that format's style when it belongs to a different one.
    public func changing(format newFormat: ExportFormat) -> ExportSpec {
        ExportSpec(style: ExportStyle.style(for: newFormat), format: newFormat, options: options)
    }

    /// The same options rendered by the first format of another style.
    public func changing(style newStyle: ExportStyle) -> ExportSpec {
        guard !newStyle.formats.contains(format), let first = newStyle.formats.first else {
            return ExportSpec(style: newStyle, format: format, options: options)
        }
        return ExportSpec(style: newStyle, format: first, options: options)
    }
}

/// A named export the user can repeat: from the Export As menu, an auto-export rule or a batch run.
public struct ExportPreset: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    public var spec: ExportSpec
    public var isBuiltIn: Bool

    public init(id: UUID = UUID(), name: String, spec: ExportSpec, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.spec = spec
        self.isBuiltIn = isBuiltIn
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        spec = try c.decode(ExportSpec.self, forKey: .spec)
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
    }
}

public extension ExportPreset {
    static let builtIns: [ExportPreset] = [
        ExportPreset(
            id: UUID(uuidString: "E0000000-0000-0000-0000-000000000001")!,
            name: "Transcript (.txt)",
            spec: .standard(for: .txt),
            isBuiltIn: true
        ),
        ExportPreset(
            id: UUID(uuidString: "E0000000-0000-0000-0000-000000000002")!,
            name: "Transcript (.md)",
            spec: .standard(for: .md),
            isBuiltIn: true
        ),
        ExportPreset(
            id: UUID(uuidString: "E0000000-0000-0000-0000-000000000003")!,
            name: "Subtitles (.srt)",
            spec: .standard(for: .srt),
            isBuiltIn: true
        ),
        ExportPreset(
            id: UUID(uuidString: "E0000000-0000-0000-0000-000000000004")!,
            name: "Subtitles (.vtt)",
            spec: .standard(for: .vtt),
            isBuiltIn: true
        ),
        ExportPreset(
            id: UUID(uuidString: "E0000000-0000-0000-0000-000000000005")!,
            name: "Segments (.json)",
            spec: .standard(for: .json),
            isBuiltIn: true
        ),
        ExportPreset(
            id: UUID(uuidString: "E0000000-0000-0000-0000-000000000006")!,
            name: "Word (.docx)",
            spec: .standard(for: .docx),
            isBuiltIn: true
        ),
        ExportPreset(
            id: UUID(uuidString: "E0000000-0000-0000-0000-000000000007")!,
            name: "PDF",
            spec: .standard(for: .pdf),
            isBuiltIn: true
        ),
    ]

    /// The built-in preset that renders this format, if one does.
    static func builtIn(for format: ExportFormat) -> ExportPreset? {
        builtIns.first { $0.spec.format == format }
    }
}
