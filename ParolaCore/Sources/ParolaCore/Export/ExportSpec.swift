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
        apply(to: segments, translation: [:]).segments
    }

    /// The same merge, carrying a translation along: a merged run's translations join with a space,
    /// exactly as its texts do.
    public func apply(
        to segments: [TranscriptSegment], translation: [Int: String]
    ) -> (segments: [TranscriptSegment], translation: [Int: String]) {
        guard self == .speakerParagraphs else { return (segments, translation) }
        var merged: [TranscriptSegment] = []
        var mergedTranslation = translation
        for segment in segments {
            guard var previous = merged.last,
                  Format.presentationSpeakerLabel(previous.speaker) == Format.presentationSpeakerLabel(segment.speaker)
            else {
                merged.append(segment)
                continue
            }
            mergedTranslation = TranscriptTranslation.merging(mergedTranslation, of: previous.id, with: segment.id)
            let head = previous.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            previous.text = [head, tail].filter { !$0.isEmpty }.joined(separator: " ")
            previous.end = max(previous.end, segment.end)
            // Half a run's word timings would read as the whole merged segment's; keep them only when every member has them.
            if let head = previous.words, let tail = segment.words {
                previous.words = head + tail
            } else {
                previous.words = nil
            }
            merged[merged.count - 1] = previous
        }
        return (merged, mergedTranslation)
    }
}

/// Which language of a translated transcript an export writes.
public enum ExportContent: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case original
    case translation
    case both

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .original: return "Original"
        case .translation: return "Translation"
        case .both: return "Original and translation"
        }
    }
}

/// One field of ``ExportOptions``. A format lists the ones it reads so the Export sheet
/// only offers what changes the output.
public enum ExportOptionField: String, Sendable, Hashable, CaseIterable, Identifiable {
    case timestamps
    case endTimestamps
    case milliseconds
    case speakers
    case captionLength
    case htmlTheme
    case grouping

    public var id: String { rawValue }
}

public extension ExportFormat {
    var optionFields: [ExportOptionField] {
        switch self {
        case .txt, .md:
            return [.timestamps, .endTimestamps, .milliseconds, .speakers, .grouping]
        case .html:
            return [.timestamps, .endTimestamps, .milliseconds, .speakers, .htmlTheme, .grouping]
        case .docx, .pdf:
            return [.speakers, .grouping]
        case .srt, .vtt:
            return [.speakers, .captionLength, .grouping]
        case .json, .jsonl, .csv, .tsv, .fcpxml, .lrc:
            return [.grouping]
        }
    }
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

    /// The same options with everything this format ignores reset to that format's standard, so a
    /// spec never carries a field the export cannot honour.
    func masked(to format: ExportFormat) -> ExportOptions {
        var out = ExportSpec.standard(for: format).options
        out.content = content
        for field in format.optionFields {
            switch field {
            case .timestamps: out.timestamps = timestamps
            case .endTimestamps: out.endTimestamps = endTimestamps
            case .milliseconds: out.milliseconds = milliseconds
            case .speakers: out.speakers = speakers
            case .captionLength: out.captionLength = captionLength
            case .htmlTheme: out.htmlTheme = htmlTheme
            case .grouping: out.grouping = grouping
            }
        }
        return out
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

    /// The same export in another format: it moves to that format's style and drops the options that format ignores.
    public func changing(format newFormat: ExportFormat) -> ExportSpec {
        ExportSpec(
            style: ExportStyle.style(for: newFormat),
            format: newFormat,
            options: options.masked(to: newFormat)
        )
    }

    /// The same options rendered by the first format of another style.
    public func changing(style newStyle: ExportStyle) -> ExportSpec {
        guard !newStyle.formats.contains(format), let first = newStyle.formats.first else {
            return changing(format: format)
        }
        return changing(format: first)
    }

    /// The transcript as this spec's format sees it: segments grouped, and the text swapped for the
    /// translation when that is what the export writes.
    func prepared(_ transcript: Transcript) -> Transcript {
        var out = transcript
        let content = resolvedContent
        let grouped = options.grouping.apply(
            to: transcript.segments,
            translation: content == .original ? [:] : (transcript.translation?.segments ?? [:])
        )
        out.segments = grouped.segments
        switch content {
        case .original:
            out.translation = nil
        case .translation:
            out.segments = out.segments.map { segment in
                guard let translated = grouped.translation[segment.id] else { return segment }
                var segment = segment
                segment.text = translated
                // The word timings belong to the original wording; they would mislabel the translation.
                segment.words = nil
                return segment
            }
            out.translation = nil
        case .both:
            out.translation = transcript.translation.map {
                var translation = $0
                translation.segments = grouped.translation
                return translation
            }
        }
        return out
    }

    /// A caption carries one text, so Final Cut reads "both" as the translation.
    var resolvedContent: ExportContent {
        format == .fcpxml && options.content == .both ? .translation : options.content
    }

    /// The spec to render when this one produces bytes no reader can show: docx and pdf preview as text.
    public var textRendering: ExportSpec {
        guard format == .docx || format == .pdf else { return self }
        return changing(format: .txt)
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
            id: defaultID(for: .txt),
            name: "Transcript (.txt)",
            spec: .standard(for: .txt),
            isBuiltIn: true
        ),
        ExportPreset(
            id: defaultID(for: .md),
            name: "Transcript (.md)",
            spec: .standard(for: .md),
            isBuiltIn: true
        ),
        ExportPreset(
            id: defaultID(for: .srt),
            name: "Subtitles (.srt)",
            spec: .standard(for: .srt),
            isBuiltIn: true
        ),
        ExportPreset(
            id: defaultID(for: .vtt),
            name: "Subtitles (.vtt)",
            spec: .standard(for: .vtt),
            isBuiltIn: true
        ),
        ExportPreset(
            id: defaultID(for: .json),
            name: "Segments (.json)",
            spec: .standard(for: .json),
            isBuiltIn: true
        ),
        ExportPreset(
            id: defaultID(for: .docx),
            name: "Word (.docx)",
            spec: .standard(for: .docx),
            isBuiltIn: true
        ),
        ExportPreset(
            id: defaultID(for: .pdf),
            name: "PDF",
            spec: .standard(for: .pdf),
            isBuiltIn: true
        ),
    ]

    /// The built-in preset that renders this format, if one does.
    static func builtIn(for format: ExportFormat) -> ExportPreset? {
        builtIns.first { $0.spec.format == format }
    }

    /// The fixed id every format's preset keeps across versions, so a saved rule survives an upgrade.
    static func defaultID(for format: ExportFormat) -> UUID {
        switch format {
        case .txt:    return uuid(1)
        case .md:     return uuid(2)
        case .srt:    return uuid(3)
        case .vtt:    return uuid(4)
        case .json:   return uuid(5)
        case .docx:   return uuid(6)
        case .pdf:    return uuid(7)
        case .html:   return uuid(8)
        case .csv:    return uuid(9)
        case .tsv:    return uuid(10)
        case .jsonl:  return uuid(11)
        case .fcpxml: return uuid(12)
        case .lrc:    return uuid(13)
        }
    }

    /// The preset a format exports with: the built-in where there is one, else a plain preset the user can delete.
    static func formatPreset(for format: ExportFormat) -> ExportPreset {
        if let builtIn = builtIn(for: format) { return builtIn }
        return ExportPreset(
            id: defaultID(for: format),
            name: format.displayName,
            spec: .standard(for: format),
            isBuiltIn: false
        )
    }

    /// The format preset with this id, for putting back a preset a saved rule still points at.
    static func formatPreset(id: UUID) -> ExportPreset? {
        guard let format = ExportFormat.allCases.first(where: { defaultID(for: $0) == id }) else { return nil }
        return formatPreset(for: format)
    }

    /// One preset per export format, the seven built-ins included.
    static var formatPresets: [ExportPreset] { ExportFormat.allCases.map { formatPreset(for: $0) } }

    private static func uuid(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "E0000000-0000-0000-0000-%012d", index))!
    }
}
