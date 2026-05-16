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

public struct HtmlExporter: TranscriptExporter {
    public let format: ExportFormat = .html
    public init() {}

    public func render(_ transcript: Transcript) throws -> Data {
        var body = ""
        for seg in transcript.segments {
            let text = Self.escape(seg.text.trimmingCharacters(in: .whitespaces))
            let ts = MarkdownExporter.timestamp(seg.start)
            let anchor = "t-\(seg.id)"
            var paragraph = "<p id=\"\(anchor)\"><a class=\"t\" href=\"#\(anchor)\">[\(ts)]</a> "
            if let speaker = seg.speaker {
                paragraph += "<span class=\"s\">\(Self.escape(speaker))</span>: "
            }
            paragraph += "\(text)</p>\n"
            body += paragraph
        }
        let doc = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>Transcript</title>
        <style>body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;max-width:720px;margin:2rem auto;padding:0 1rem;line-height:1.5}.t{color:#888;font-family:ui-monospace,monospace;font-size:.85em;text-decoration:none;margin-right:.4em}.s{font-weight:600}p{margin:0 0 1em}</style>
        </head><body>
        \(body)</body></html>
        """
        return utf8(doc)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

public struct CsvExporter: TranscriptExporter {
    public let format: ExportFormat = .csv
    public init() {}

    public func render(_ transcript: Transcript) throws -> Data {
        var out = "start_seconds,end_seconds,speaker,text\n"
        for seg in transcript.segments {
            let speaker = seg.speaker ?? ""
            let text = seg.text.trimmingCharacters(in: .whitespaces)
            out += "\(seg.start),\(seg.end),\(Self.quote(speaker)),\(Self.quote(text))\n"
        }
        return utf8(out)
    }

    static func quote(_ s: String) -> String {
        let needsQuotes = s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r")
        guard needsQuotes else { return s }
        let escaped = s.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}

public struct DocxExporter: TranscriptExporter {
    public let format: ExportFormat = .docx
    public init() {}

    public func render(_ transcript: Transcript) throws -> Data {
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
            let text = HtmlExporter.escape(seg.text.trimmingCharacters(in: .whitespaces))
            if let speaker = seg.speaker {
                let escapedSpeaker = HtmlExporter.escape(speaker)
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
