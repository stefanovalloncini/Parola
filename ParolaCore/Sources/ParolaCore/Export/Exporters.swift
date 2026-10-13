import Foundation

public enum ExportFormat: String, CaseIterable, Sendable, Codable, Identifiable {
    case txt
    case srt
    case vtt
    case json
    case jsonl
    case md
    case html
    case csv
    case tsv
    case docx
    case pdf
    case fcpxml
    case lrc

    public var id: String { rawValue }
    public var fileExtension: String { rawValue }

    /// Human-readable name shared by every export menu and format card.
    public var displayName: String {
        switch self {
        case .txt: return "Plain Text"
        case .srt: return "SubRip Subtitles"
        case .vtt: return "WebVTT Subtitles"
        case .json: return "JSON"
        case .jsonl: return "JSON Lines"
        case .md: return "Markdown"
        case .html: return "HTML"
        case .csv: return "CSV"
        case .tsv: return "TSV"
        case .docx: return "Word Document"
        case .pdf: return "PDF"
        case .fcpxml: return "Final Cut Pro XML"
        case .lrc: return "LRC Lyrics"
        }
    }
}

public protocol TranscriptExporter: Sendable {
    var format: ExportFormat { get }
    var spec: ExportSpec { get }
    /// The bytes for this format. Call ``render(_:)`` instead: it applies the spec's shared transforms first.
    func encode(_ transcript: Transcript) throws -> Data
    /// The bytes for the transcript as the spec describes it.
    func render(_ transcript: Transcript) throws -> Data
}

public extension TranscriptExporter {
    var options: ExportOptions { spec.options }

    /// Renders the transcript as the spec describes it: segments grouped, and the content mode
    /// settled, before the format sees them.
    func render(_ transcript: Transcript) throws -> Data {
        try encode(spec.prepared(transcript))
    }

    /// The translation a format writes next to a segment's own text, or nil when this export
    /// writes one language.
    internal func translation(for segment: TranscriptSegment, in transcript: Transcript) -> String? {
        guard spec.resolvedContent == .both else { return nil }
        let text = transcript.translation?.segments[segment.id]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    func renderText(_ transcript: Transcript) throws -> String {
        let data = try render(transcript)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ParolaError.ioError("Export format \(format.rawValue) produced non-UTF-8 bytes; use render(_:) for the raw data.")
        }
        return text
    }
}

func utf8(_ s: String) -> Data { Data(s.utf8) }

public enum Exporters {
    public static func exporter(for spec: ExportSpec) -> TranscriptExporter {
        switch spec.format {
        case .txt:  return TxtExporter(spec: spec)
        case .srt:  return SrtExporter(spec: spec)
        case .vtt:  return VttExporter(spec: spec)
        case .json: return JsonExporter(spec: spec)
        case .jsonl: return JsonLinesExporter(spec: spec)
        case .md:   return MarkdownExporter(spec: spec)
        case .html: return HtmlExporter(spec: spec)
        case .csv:  return CsvExporter(spec: spec)
        case .tsv:  return TsvExporter(spec: spec)
        case .docx: return DocxExporter(spec: spec)
        case .pdf:  return PdfExporter(spec: spec)
        case .fcpxml: return FcpxmlExporter(spec: spec)
        case .lrc:  return LrcExporter(spec: spec)
        }
    }

    /// The exporter a format uses when nothing has been configured.
    public static func exporter(for format: ExportFormat) -> TranscriptExporter {
        exporter(for: .standard(for: format))
    }
}
