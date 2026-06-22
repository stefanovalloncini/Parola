import Foundation

public struct JsonExporter: TranscriptExporter {
    public let format: ExportFormat = .json
    public init() {}
    public func render(_ transcript: Transcript) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(transcript)
    }
}

struct JsonLinesExporter: TranscriptExporter {
    let format: ExportFormat = .jsonl
    init() {}
    func render(_ transcript: Transcript) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for segment in transcript.segments {
            data.append(try encoder.encode(segment))
            data.append(0x0A)
        }
        return data
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

public struct HtmlOptions: Sendable, Codable, Hashable {
    public var theme: HtmlExportTheme
    public var showTimestamps: Bool

    public init(theme: HtmlExportTheme = .light, showTimestamps: Bool = true) {
        self.theme = theme
        self.showTimestamps = showTimestamps
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme = try c.decodeIfPresent(HtmlExportTheme.self, forKey: .theme) ?? .light
        showTimestamps = try c.decodeIfPresent(Bool.self, forKey: .showTimestamps) ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case theme
        case showTimestamps
    }
}

public struct HtmlExporter: TranscriptExporter {
    public let format: ExportFormat = .html
    public let options: HtmlOptions

    public init(options: HtmlOptions = HtmlOptions()) {
        self.options = options
    }

    public func render(_ transcript: Transcript) throws -> Data {
        var body = ""
        for seg in transcript.segments {
            let trimmed = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let text = Format.escapeHTML(trimmed)
            let anchor = "t-\(seg.id)"
            var paragraph = "<p id=\"\(anchor)\">"
            if options.showTimestamps {
                paragraph += "<a class=\"t\" href=\"#\(anchor)\">[\(Format.timestampHHMMSS(seg.start))]</a> "
            }
            if let speaker = seg.speaker, !speaker.isEmpty {
                paragraph += "<span class=\"s\">\(Format.escapeHTML(speaker))</span>: "
            }
            paragraph += "\(text)</p>\n"
            body += paragraph
        }
        let theme = options.theme
        let css = "body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;max-width:720px;margin:2rem auto;padding:0 1rem;line-height:1.5;background:\(theme.background);color:\(theme.foreground)}.t{color:\(theme.timestamp);font-family:ui-monospace,monospace;font-size:.85em;text-decoration:none;margin-right:.4em}.s{font-weight:600}p{margin:0 0 1em}"
        let doc = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>Transcript</title>
        <style>\(css)</style>
        </head><body>
        \(body)</body></html>
        """
        return utf8(doc)
    }
}

struct CsvExporter: TranscriptExporter {
    let format: ExportFormat = .csv
    init() {}

    func render(_ transcript: Transcript) throws -> Data {
        var out = "start_seconds,end_seconds,speaker,text\n"
        for seg in transcript.segments {
            let speaker = seg.speaker ?? ""
            let text = seg.text.trimmingCharacters(in: .whitespaces)
            out += "\(Format.decimalSeconds(seg.start)),\(Format.decimalSeconds(seg.end)),\(Self.quote(speaker)),\(Self.quote(text))\n"
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
    init() {}

    func render(_ transcript: Transcript) throws -> Data {
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
            if let speaker = seg.speaker, !speaker.isEmpty {
                let escapedSpeaker = Format.escapeXML(speaker)
                body += "<w:p><w:r><w:rPr><w:b/></w:rPr><w:t xml:space=\"preserve\">\(escapedSpeaker): </w:t></w:r><w:r><w:t xml:space=\"preserve\">\(text)</w:t></w:r></w:p>"
            } else {
                body += "<w:p><w:r><w:t xml:space=\"preserve\">\(text)</w:t></w:r></w:p>"
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
