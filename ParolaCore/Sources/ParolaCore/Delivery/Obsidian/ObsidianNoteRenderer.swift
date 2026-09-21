import Foundation

/// Which keys a note's YAML frontmatter carries.
public struct ObsidianFrontmatterOptions: Codable, Sendable, Equatable {
    public var title: Bool
    public var date: Bool
    public var duration: Bool
    public var source: Bool
    public var language: Bool
    public var model: Bool
    public var speakers: Bool
    public var tags: Bool
    public var summary: Bool

    public init(
        title: Bool = true,
        date: Bool = true,
        duration: Bool = true,
        source: Bool = true,
        language: Bool = true,
        model: Bool = true,
        speakers: Bool = true,
        tags: Bool = true,
        summary: Bool = true
    ) {
        self.title = title
        self.date = date
        self.duration = duration
        self.source = source
        self.language = language
        self.model = model
        self.speakers = speakers
        self.tags = tags
        self.summary = summary
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(Bool.self, forKey: .title) ?? true
        date = try c.decodeIfPresent(Bool.self, forKey: .date) ?? true
        duration = try c.decodeIfPresent(Bool.self, forKey: .duration) ?? true
        source = try c.decodeIfPresent(Bool.self, forKey: .source) ?? true
        language = try c.decodeIfPresent(Bool.self, forKey: .language) ?? true
        model = try c.decodeIfPresent(Bool.self, forKey: .model) ?? true
        speakers = try c.decodeIfPresent(Bool.self, forKey: .speakers) ?? true
        tags = try c.decodeIfPresent(Bool.self, forKey: .tags) ?? true
        summary = try c.decodeIfPresent(Bool.self, forKey: .summary) ?? true
    }
}

/// Which sections a note's body carries.
public struct ObsidianBodyOptions: Codable, Sendable, Equatable {
    public var summary: Bool
    public var transcript: Bool
    public var timestamps: Bool
    public var speakers: Bool
    public var favorites: Bool

    public init(
        summary: Bool = true,
        transcript: Bool = true,
        timestamps: Bool = false,
        speakers: Bool = true,
        favorites: Bool = true
    ) {
        self.summary = summary
        self.transcript = transcript
        self.timestamps = timestamps
        self.speakers = speakers
        self.favorites = favorites
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decodeIfPresent(Bool.self, forKey: .summary) ?? true
        transcript = try c.decodeIfPresent(Bool.self, forKey: .transcript) ?? true
        timestamps = try c.decodeIfPresent(Bool.self, forKey: .timestamps) ?? false
        speakers = try c.decodeIfPresent(Bool.self, forKey: .speakers) ?? true
        favorites = try c.decodeIfPresent(Bool.self, forKey: .favorites) ?? true
    }
}

/// Everything the renderer needs beyond the payload.
public struct ObsidianNoteOptions: Sendable, Equatable {
    public var frontmatter: ObsidianFrontmatterOptions
    public var body: ObsidianBodyOptions
    public var wikilinks: Bool

    public init(
        frontmatter: ObsidianFrontmatterOptions = ObsidianFrontmatterOptions(),
        body: ObsidianBodyOptions = ObsidianBodyOptions(),
        wikilinks: Bool = false
    ) {
        self.frontmatter = frontmatter
        self.body = body
        self.wikilinks = wikilinks
    }
}

/// Turns a payload into the Markdown of one Obsidian note. Pure: the same payload and options
/// always produce the same bytes.
public enum ObsidianNoteRenderer {
    public static func render(
        _ payload: DeliveryPayload,
        options: ObsidianNoteOptions,
        title: String
    ) -> String {
        var blocks: [String] = []
        if let frontmatter = frontmatter(payload, options: options, title: title) {
            blocks.append(frontmatter)
        }
        blocks.append("# \(oneLine(title))")
        if options.body.summary, let summary = summarySection(payload) {
            blocks.append(summary)
        }
        if options.body.transcript, let transcript = transcriptSection(payload, options: options) {
            blocks.append(transcript)
        }
        if options.body.favorites, let favorites = favoritesSection(payload, options: options) {
            blocks.append(favorites)
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// The note's filename without its extension: tokens replaced, then made safe for the filesystem.
    /// `{title}` is always the entry's own title; the title format governs the note's heading and
    /// its frontmatter, not what the file is called.
    public static func filename(
        template: String,
        payload: DeliveryPayload,
        timeZone: TimeZone = .current
    ) -> String {
        let pattern = template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{title}" : template
        let filled = pattern
            .replacingOccurrences(of: "{title}", with: payload.title)
            .replacingOccurrences(of: "{date}", with: DeliveryDateFormat.day(payload.createdAt, timeZone: timeZone))
            .replacingOccurrences(of: "{time}", with: DeliveryDateFormat.time(payload.createdAt, timeZone: timeZone))
            .replacingOccurrences(of: "{category}", with: payload.category.rawValue)
        return sanitisedFilename(filled)
    }

    /// The tokens a filename template understands, in the order the editor lists them.
    public static let filenameTokens = ["{title}", "{date}", "{time}", "{category}"]

    public static func sanitisedFilename(_ raw: String) -> String {
        sanitisedPathComponent(raw) ?? "Untitled"
    }

    /// The same cleanup as ``sanitisedFilename(_:)``, but nil where nothing usable is left — a
    /// subfolder drops such a component instead of creating one called "Untitled".
    static func sanitisedPathComponent(_ raw: String) -> String? {
        var name = oneLine(raw)
        for character in "/\\:*?\"<>|" {
            name = name.replacingOccurrences(of: String(character), with: "-")
        }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.count > 200 {
            name = String(name.prefix(200)).trimmingCharacters(in: .whitespaces)
        }
        // A leading dot would hide the note from Obsidian and from Finder, and it is also what
        // turns a "../" step in a subfolder into nothing.
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    // MARK: - Frontmatter

    private static func frontmatter(
        _ payload: DeliveryPayload,
        options: ObsidianNoteOptions,
        title: String
    ) -> String? {
        var lines: [String] = []
        let fields = options.frontmatter
        if fields.title {
            lines.append("title: \(quoted(title))")
        }
        if fields.date {
            lines.append("date: \(Date.ISO8601FormatStyle().format(payload.createdAt))")
        }
        if fields.duration, let duration = payload.duration, duration > 0 {
            lines.append("duration: \(quoted(Timecode.format(duration)))")
        }
        if fields.source, let source = payload.sourceURL {
            lines.append("source: \(quoted(source.isFileURL ? source.path : source.absoluteString))")
        }
        if fields.language, !payload.language.isEmpty {
            lines.append("language: \(quoted(payload.language))")
        }
        if fields.model, !payload.modelName.isEmpty {
            lines.append("model: \(quoted(payload.modelName))")
        }
        if fields.speakers, !payload.speakers.isEmpty {
            lines.append("speakers: \(list(payload.speakers.map { speakerName($0, options: options) }))")
        }
        if fields.tags {
            let tags = self.tags(payload)
            if !tags.isEmpty { lines.append("tags: \(list(tags))") }
        }
        if fields.summary, let summary = payload.shortSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            lines.append("summary: \(quoted(summary))")
        }
        guard !lines.isEmpty else { return nil }
        return (["---"] + lines + ["---"]).joined(separator: "\n")
    }

    /// Obsidian reads a tag up to the first space, so a label with spaces is joined with dashes.
    private static func tags(_ payload: DeliveryPayload) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in payload.labels + [payload.category.rawValue] {
            let tag = oneLine(raw)
                .replacingOccurrences(of: "#", with: "")
                .split(separator: " ", omittingEmptySubsequences: true)
                .joined(separator: "-")
            guard !tag.isEmpty, seen.insert(tag).inserted else { continue }
            out.append(tag)
        }
        return out
    }

    // MARK: - Body

    private static func summarySection(_ payload: DeliveryPayload) -> String? {
        let text = (payload.summary?.text ?? payload.shortSummary ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let actionItems = (payload.summary?.actionItems ?? []).map(oneLine).filter { !$0.isEmpty }
        let chapters = payload.summary?.chapters ?? []
        guard !text.isEmpty || !actionItems.isEmpty || !chapters.isEmpty else { return nil }

        var blocks = ["## Summary"]
        if !text.isEmpty { blocks.append(text) }
        if !actionItems.isEmpty {
            blocks.append("### Action items")
            blocks.append(actionItems.map { "- [ ] \($0)" }.joined(separator: "\n"))
        }
        if !chapters.isEmpty {
            blocks.append("### Chapters")
            blocks.append(
                chapters
                    .map { "- \(Timecode.format($0.start)) — \(oneLine($0.title))" }
                    .joined(separator: "\n")
            )
        }
        return blocks.joined(separator: "\n\n")
    }

    private static func transcriptSection(
        _ payload: DeliveryPayload,
        options: ObsidianNoteOptions
    ) -> String? {
        let paragraphs = payload.transcript.segments.compactMap { segment in
            line(for: segment, options: options)
        }
        guard !paragraphs.isEmpty else { return nil }
        return (["## Transcript"] + paragraphs).joined(separator: "\n\n")
    }

    private static func favoritesSection(
        _ payload: DeliveryPayload,
        options: ObsidianNoteOptions
    ) -> String? {
        let bullets = payload.favoriteSegments.compactMap { segment in
            line(for: segment, options: options).map { "- \($0)" }
        }
        guard !bullets.isEmpty else { return nil }
        return "## Favorites\n\n" + bullets.joined(separator: "\n")
    }

    private static func line(for segment: TranscriptSegment, options: ObsidianNoteOptions) -> String? {
        let text = oneLine(segment.text)
        guard !text.isEmpty else { return nil }
        let speaker = options.body.speakers
            ? Format.presentationSpeakerLabel(segment.speaker).map { speakerName($0, options: options) }
            : nil
        let stamp = options.body.timestamps ? Timecode.format(segment.start) : nil
        switch (speaker, stamp) {
        case (let speaker?, let stamp?): return "**\(speaker)** *[\(stamp)]*: \(text)"
        case (let speaker?, nil): return "**\(speaker):** \(text)"
        case (nil, let stamp?): return "*[\(stamp)]* \(text)"
        case (nil, nil): return text
        }
    }

    private static func speakerName(_ name: String, options: ObsidianNoteOptions) -> String {
        let flattened = oneLine(name)
        guard options.wikilinks, !flattened.isEmpty else { return flattened }
        return "[[\(flattened)]]"
    }

    // MARK: - YAML

    private static func quoted(_ value: String) -> String {
        let escaped = oneLine(value)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func list(_ values: [String]) -> String {
        "[\(values.map(quoted).joined(separator: ", "))]"
    }

    /// Frontmatter values and Markdown lines both break on a newline, and a run of spaces at the
    /// end of a line is invisible noise in a diff.
    private static func oneLine(_ value: String) -> String {
        value
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
