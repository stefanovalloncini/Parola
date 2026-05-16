import Foundation

public enum ExportFormat: String, CaseIterable, Sendable, Codable {
    case txt
    case srt
    case vtt
    case json
    case md
    case html
    case csv

    public var fileExtension: String { rawValue }
}

public struct MarkdownOptions: Sendable {
    public var showTimestamps: Bool

    public init(showTimestamps: Bool = false) {
        self.showTimestamps = showTimestamps
    }
}

public struct MarkdownExporter: TranscriptExporter {
    public let format: ExportFormat = .md
    public let options: MarkdownOptions

    public init(options: MarkdownOptions = MarkdownOptions()) {
        self.options = options
    }

    public func render(_ transcript: Transcript) throws -> String {
        var out = ""
        for seg in transcript.segments {
            let body = seg.text.trimmingCharacters(in: .whitespaces)
            switch (seg.speaker, options.showTimestamps) {
            case (let speaker?, true):
                out += "**\(speaker)** *[\(Self.timestamp(seg.start))]*: \(body)\n\n"
            case (let speaker?, false):
                out += "**\(speaker):** \(body)\n\n"
            case (nil, true):
                out += "*[\(Self.timestamp(seg.start))]* \(body)\n\n"
            case (nil, false):
                out += "\(body)\n\n"
            }
        }
        return String(out.dropLast())
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total / 60) % 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

public protocol TranscriptExporter: Sendable {
    var format: ExportFormat { get }
    func render(_ transcript: Transcript) throws -> String
}

public struct TxtExporter: TranscriptExporter {
    public let format: ExportFormat = .txt
    public init() {}
    public func render(_ transcript: Transcript) throws -> String {
        transcript.segments
            .map { $0.text.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
    }
}

public struct SrtExporter: TranscriptExporter {
    public let format: ExportFormat = .srt
    public init() {}
    public func render(_ transcript: Transcript) throws -> String {
        var out = ""
        for (i, seg) in transcript.segments.enumerated() {
            out += "\(i + 1)\n"
            out += "\(Self.srtTimestamp(seg.start)) --> \(Self.srtTimestamp(seg.end))\n"
            out += seg.text.trimmingCharacters(in: .whitespaces) + "\n\n"
        }
        return out
    }

    static func srtTimestamp(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let total = Int((clamped * 1000).rounded())
        let ms = total % 1000
        let s = (total / 1000) % 60
        let m = (total / 60_000) % 60
        let h = total / 3_600_000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}

public struct VttExporter: TranscriptExporter {
    public let format: ExportFormat = .vtt
    public init() {}
    public func render(_ transcript: Transcript) throws -> String {
        var out = "WEBVTT\n\n"
        for seg in transcript.segments {
            out += "\(Self.vttTimestamp(seg.start)) --> \(Self.vttTimestamp(seg.end))\n"
            out += seg.text.trimmingCharacters(in: .whitespaces) + "\n\n"
        }
        return out
    }

    static func vttTimestamp(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let total = Int((clamped * 1000).rounded())
        let ms = total % 1000
        let s = (total / 1000) % 60
        let m = (total / 60_000) % 60
        let h = total / 3_600_000
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }
}

public struct JsonExporter: TranscriptExporter {
    public let format: ExportFormat = .json
    public init() {}
    public func render(_ transcript: Transcript) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(transcript)
        return String(decoding: data, as: UTF8.self)
    }
}

public struct HtmlExporter: TranscriptExporter {
    public let format: ExportFormat = .html
    public init() {}

    public func render(_ transcript: Transcript) throws -> String {
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
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>Transcript</title>
        <style>body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;max-width:720px;margin:2rem auto;padding:0 1rem;line-height:1.5}.t{color:#888;font-family:ui-monospace,monospace;font-size:.85em;text-decoration:none;margin-right:.4em}.s{font-weight:600}p{margin:0 0 1em}</style>
        </head><body>
        \(body)</body></html>
        """
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

    public func render(_ transcript: Transcript) throws -> String {
        var out = "start_seconds,end_seconds,speaker,text\n"
        for seg in transcript.segments {
            let speaker = seg.speaker ?? ""
            let text = seg.text.trimmingCharacters(in: .whitespaces)
            out += "\(seg.start),\(seg.end),\(Self.quote(speaker)),\(Self.quote(text))\n"
        }
        return out
    }

    static func quote(_ s: String) -> String {
        let needsQuotes = s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r")
        guard needsQuotes else { return s }
        let escaped = s.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}

public enum Exporters {
    public static func exporter(for format: ExportFormat) -> TranscriptExporter {
        switch format {
        case .txt:  return TxtExporter()
        case .srt:  return SrtExporter()
        case .vtt:  return VttExporter()
        case .json: return JsonExporter()
        case .md:   return MarkdownExporter()
        case .html: return HtmlExporter()
        case .csv:  return CsvExporter()
        }
    }
}
