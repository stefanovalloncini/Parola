import Foundation

public enum ExportFormat: String, CaseIterable, Sendable, Codable {
    case txt
    case srt
    case vtt
    case json

    public var fileExtension: String { rawValue }
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

public enum Exporters {
    public static func exporter(for format: ExportFormat) -> TranscriptExporter {
        switch format {
        case .txt:  return TxtExporter()
        case .srt:  return SrtExporter()
        case .vtt:  return VttExporter()
        case .json: return JsonExporter()
        }
    }
}
