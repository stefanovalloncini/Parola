import Foundation

public struct JsonExporter: TranscriptExporter {
    public let format: ExportFormat = .json
    public let spec: ExportSpec

    public init(spec: ExportSpec = .standard(for: .json)) {
        self.spec = spec
    }

    public func encode(_ transcript: Transcript) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(JsonExport(transcript))
    }
}

/// A .json export: the model's keys for what a reader needs, without the AI chat, the run timing or the source's folder.
private struct JsonExport: Encodable {
    let schemaVersion: Int
    let segments: [TranscriptSegment]
    let language: String
    let modelName: String
    /// A file's name alone, or a link as it is, under the model's key so the export still decodes as a `Transcript`.
    let sourceURL: String?
    let durationSeconds: Double?
    let summary: Summary?
    let translation: TranscriptTranslation?

    init(_ transcript: Transcript) {
        schemaVersion = transcript.schemaVersion
        segments = transcript.segments.droppingBlankText()
        language = transcript.language
        modelName = transcript.modelName
        sourceURL = transcript.sourceURL.map { $0.isFileURL ? $0.lastPathComponent : $0.absoluteString }
        durationSeconds = transcript.durationSeconds
        summary = transcript.summary
        translation = transcript.translation
    }
}

struct JsonLinesExporter: TranscriptExporter {
    let format: ExportFormat = .jsonl
    let spec: ExportSpec

    init(spec: ExportSpec = .standard(for: .jsonl)) {
        self.spec = spec
    }

    func encode(_ transcript: Transcript) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for segment in transcript.segments.droppingBlankText() {
            let line = TranslatedSegment(segment: segment, translation: translation(for: segment, in: transcript))
            data.append(try encoder.encode(line))
            data.append(0x0A)
        }
        return data
    }
}

/// A segment plus the translation of its text, as one flat JSON object.
private struct TranslatedSegment: Encodable {
    enum ExtraKey: String, CodingKey { case translation }

    let segment: TranscriptSegment
    let translation: String?

    func encode(to encoder: any Encoder) throws {
        try segment.encode(to: encoder)
        guard let translation else { return }
        var container = encoder.container(keyedBy: ExtraKey.self)
        try container.encode(translation, forKey: .translation)
    }
}

public enum HtmlExportTheme: String, Sendable, Codable, CaseIterable, Identifiable {
    case light
    case dark
    case sepia

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .light: return "Light"
        case .dark:  return "Dark"
        case .sepia: return "Sepia"
        }
    }

    var background: String {
        switch self {
        case .light: return "#ffffff"
        case .dark:  return "#111111"
        case .sepia: return "#f4ecd8"
        }
    }

    var foreground: String {
        switch self {
        case .light: return "#111111"
        case .dark:  return "#eeeeee"
        case .sepia: return "#3a2d1f"
        }
    }

    var timestamp: String {
        switch self {
        case .light: return "#888888"
        case .dark:  return "#999999"
        case .sepia: return "#9a7a48"
        }
    }
}

public struct HtmlExporter: TranscriptExporter {
    public let format: ExportFormat = .html
    public let spec: ExportSpec

    public init(spec: ExportSpec = .standard(for: .html)) {
        self.spec = spec
    }

    public func encode(_ transcript: Transcript) throws -> Data {
        var body = ""
        for seg in transcript.segments {
            let trimmed = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let text = Format.escapeHTML(trimmed)
            let anchor = "t-\(seg.id)"
            var paragraph = "<p id=\"\(anchor)\">"
            if let stamp = options.timestampLabel(start: seg.start, end: seg.end) {
                paragraph += "<a class=\"t\" href=\"#\(anchor)\">[\(Format.escapeHTML(stamp))]</a> "
            }
            if options.speakers, let speaker = Format.presentationSpeakerLabel(seg.speaker) {
                paragraph += "<span class=\"s\">\(Format.escapeHTML(speaker))</span>: "
            }
            paragraph += text
            if let translated = translation(for: seg, in: transcript) {
                paragraph += "<br><span class=\"x\">\(Format.escapeHTML(translated))</span>"
            }
            paragraph += "</p>\n"
            body += paragraph
        }
        let theme = options.htmlTheme
        let title = Format.escapeHTML(Format.documentTitle(for: transcript, options: options))
        let css = "body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;max-width:720px;margin:2rem auto;padding:0 1rem;line-height:1.5;background:\(theme.background);color:\(theme.foreground)}.t{color:\(theme.timestamp);font-family:ui-monospace,monospace;font-size:.85em;text-decoration:none;margin-right:.4em}.s{font-weight:600}p{margin:0 0 1em}"
        // Only for a two-language export, so a single-language one keeps its exact bytes.
        let translationCSS = spec.resolvedContent == .both ? ".x{color:\(theme.timestamp)}" : ""
        let doc = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(title)</title>
        <style>\(css)\(translationCSS)</style>
        </head><body>
        \(body)</body></html>
        """
        return utf8(doc)
    }
}

struct CsvExporter: TranscriptExporter {
    let format: ExportFormat = .csv
    let spec: ExportSpec

    init(spec: ExportSpec = .standard(for: .csv)) {
        self.spec = spec
    }

    func encode(_ transcript: Transcript) throws -> Data {
        let writesTranslation = spec.resolvedContent == .both
        var out = "start_seconds,end_seconds,speaker,text"
        out += writesTranslation ? ",translation\n" : "\n"
        for seg in transcript.segments {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let speaker = Format.presentationSpeakerLabel(seg.speaker) ?? ""
            out += "\(Format.decimalSeconds(seg.start)),\(Format.decimalSeconds(seg.end)),\(Self.quote(speaker)),\(Self.quote(text))"
            if writesTranslation {
                out += ",\(Self.quote(translation(for: seg, in: transcript) ?? ""))"
            }
            out += "\n"
        }
        return utf8(out)
    }

    static func quote(_ s: String) -> String {
        let needsQuotes = s.contains(",") || s.contains("\"") || s.unicodeScalars.contains("\n") || s.unicodeScalars.contains("\r")
        guard needsQuotes else { return s }
        let escaped = s.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}

struct DocxExporter: TranscriptExporter {
    let format: ExportFormat = .docx
    let spec: ExportSpec

    init(spec: ExportSpec = .standard(for: .docx)) {
        self.spec = spec
    }

    func encode(_ transcript: Transcript) throws -> Data {
        let document = buildDocumentXML(transcript)
        let files: [Zip.File] = [
            Zip.File(name: "[Content_Types].xml", data: utf8(Self.contentTypesXML)),
            Zip.File(name: "_rels/.rels", data: utf8(Self.relsXML)),
            Zip.File(name: "word/document.xml", data: utf8(document))
        ]
        return Zip.archive(files)
    }

    private func buildDocumentXML(_ transcript: Transcript) -> String {
        var body = ""
        for seg in transcript.segments {
            let trimmed = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let text = Format.escapeXML(trimmed)
            let tail = translation(for: seg, in: transcript).map {
                "<w:r><w:br/><w:t xml:space=\"preserve\">\(Format.escapeXML($0))</w:t></w:r>"
            } ?? ""
            if options.speakers, let speaker = Format.presentationSpeakerLabel(seg.speaker) {
                let escapedSpeaker = Format.escapeXML(speaker)
                body += "<w:p><w:r><w:rPr><w:b/></w:rPr><w:t xml:space=\"preserve\">\(escapedSpeaker): </w:t></w:r><w:r><w:t xml:space=\"preserve\">\(text)</w:t></w:r>\(tail)</w:p>"
            } else {
                body += "<w:p><w:r><w:t xml:space=\"preserve\">\(text)</w:t></w:r>\(tail)</w:p>"
            }
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body)</w:body></w:document>
        """
    }

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
    """

    private static let relsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
    """
}
