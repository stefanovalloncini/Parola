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
    func render(_ transcript: Transcript) throws -> Data
}

public extension TranscriptExporter {
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
    public static func exporter(for format: ExportFormat) -> TranscriptExporter {
        switch format {
        case .txt:  return TxtExporter()
        case .srt:  return SrtExporter()
        case .vtt:  return VttExporter()
        case .json: return JsonExporter()
        case .jsonl: return JsonLinesExporter()
        case .md:   return MarkdownExporter()
        case .html: return HtmlExporter()
        case .csv:  return CsvExporter()
        case .tsv:  return TsvExporter()
        case .docx: return DocxExporter()
        case .pdf:  return PdfExporter()
        case .fcpxml: return FcpxmlExporter()
        case .lrc:  return LrcExporter()
        }
    }
}
